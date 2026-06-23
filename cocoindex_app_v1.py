"""
CocoIndex v1 code-indexing application for the captain's repos.

Walks a list of source directories, syntax-chunks source files with tree-sitter,
embeds each chunk with a local SentenceTransformer model, extracts per-function
and per-file summaries via LiteLLM (defaults to ``MiniMax-M3``), and exports the
results into three SQLite tables (``chunk_embeddings``, ``func_summaries``,
``file_summaries``).

Usage:
    # Catch-up (one-shot):
    COCOINDEX_DB=./cocoindex_state cocoindex update cocoindex_app_v1.py

    # Live mode (re-index on file change):
    COCOINDEX_DB=./cocoindex_state cocoindex update cocoindex_app_v1.py -L

    # Multiple / different source roots (colon- or whitespace-separated):
    COCOINDEX_SOURCES="~/projects/orbit:~/projects/memjuice:~/projects/treehouse \\
                       ~/projects/mintmux:~/projects/firstmate" \\
        COCOINDEX_DB=./cocoindex_state cocoindex update cocoindex_app_v1.py

Two paths are involved (CocoIndex v1 uses LMDB for internal state, SQLite for data):
    COCOINDEX_DB            -> LMDB state DIRECTORY (existing CocoIndex convention;
                                always required by the CLI; treated as a directory)
    COCOINDEX_SQLITE_PATH   -> SQLite file holding the three data tables
                                (defaults to ``<COCOINDEX_DB>/cocoindex_data.db``)

LLM configuration via env vars (passed straight through to LiteLLM):
    LITELLM_MODEL              default: ``MiniMax-M3``
    OPENAI_API_BASE / OPENAI_API_KEY / ANTHROPIC_API_KEY / etc.
No provider secrets are hardcoded or read from disk; LiteLLM resolves them
from the environment at call time.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys
from dataclasses import dataclass
from typing import Annotated, AsyncIterator

import cocoindex as coco
from cocoindex.connectors import localfs, sqlite
from cocoindex.ops.code import CodeAst
from cocoindex.ops.sentence_transformers import SentenceTransformerEmbedder
from cocoindex.ops.text import detect_code_language
from cocoindex.resources.chunk import Chunk, TextPosition
from cocoindex.resources.file import FileLike, PatternFilePathMatcher
from cocoindex.resources.id import IdGenerator
from numpy.typing import NDArray


# ── Config (env-driven; no secrets embedded) ─────────────────────────────────

def _resolve_sources() -> list[pathlib.Path]:
    """Return the list of source roots to walk.

    ``COCOINDEX_SOURCES`` is a colon- or whitespace-separated list of paths.
    Default: ``~/projects/{orbit,memjuice,treehouse,mintmux,firstmate}`` if they
    exist, else just ``~/projects``.
    """
    raw = os.environ.get("COCOINDEX_SOURCES")
    home = pathlib.Path(os.environ.get("HOME", str(pathlib.Path.home())))
    if raw:
        roots: list[pathlib.Path] = []
        for tok in re.split(r"[\s,:]+", raw.strip()):
            if not tok:
                continue
            p = pathlib.Path(os.path.expanduser(tok)).resolve()
            if p.exists():
                roots.append(p)
        if roots:
            return roots
        # fall through to default if all paths were bogus
    defaults = ["orbit", "memjuice", "treehouse", "mintmux", "firstmate"]
    roots = [home / "projects" / name for name in defaults if (home / "projects" / name).exists()]
    if not roots:
        roots = [home / "projects"]
    return roots


CHUNK_SIZE = int(os.environ.get("COCOINDEX_CHUNK_SIZE", "1500"))
CHUNK_OVERLAP = int(os.environ.get("COCOINDEX_CHUNK_OVERLAP", "200"))
EMBED_MODEL = os.environ.get(
    "COCOINDEX_EMBED_MODEL", "sentence-transformers/all-MiniLM-L6-v2"
)
LITELLM_MODEL = os.environ.get("LITELLM_MODEL", "MiniMax-M3")
LITELLM_TIMEOUT = float(os.environ.get("COCOINDEX_LITELLM_TIMEOUT", "30"))

SUPPORTED_EXTENSIONS = (
    ".go", ".py", ".ts", ".tsx", ".js", ".rs", ".swift",
    ".zig", ".lua", ".rb",
)

# Truncation limits for LLM extraction prompts. Keep these small to stay cheap.
MAX_CHUNK_PROMPT_CHARS = int(os.environ.get("COCOINDEX_MAX_CHUNK_PROMPT_CHARS", "2000"))
MAX_FILE_PROMPT_CHARS = int(os.environ.get("COCOINDEX_MAX_FILE_PROMPT_CHARS", "1500"))


# ── Context keys (shared, durable identities) ────────────────────────────────

SQLITE_DB = coco.ContextKey[sqlite.ManagedConnection]("sqlite_db")
EMBEDDER = coco.ContextKey[SentenceTransformerEmbedder]("embedder")


# ── Output schemas ────────────────────────────────────────────────────────────

@dataclass
class ChunkEmbedding:
    """One per syntax-chunked region of source."""

    id: int
    filename: str
    language: str
    start_line: int
    end_line: int
    text: str
    embedding: Annotated[NDArray, EMBEDDER]


@dataclass
class FuncSummary:
    """One per extracted function within a chunk."""

    id: int
    filename: str
    language: str
    func_name: str
    signature: str
    summary: str
    calls_json: str  # JSON array of callee names


@dataclass
class FileSummary:
    """One per source file."""

    id: int
    filename: str
    language: str
    purpose: str
    exports_json: str  # JSON array of exported names
    depends_on_json: str  # JSON array of import targets


# ── Lifespan: open SQLite + warm the embedder ─────────────────────────────────

def _resolve_sqlite_path() -> pathlib.Path:
    """Pick the SQLite path for the data tables.

    Default: ``<COCOINDEX_DB>/cocoindex_data.db`` so the LMDB state directory
    and the SQLite data file live side by side under the same root. Override
    with ``COCOINDEX_SQLITE_PATH`` to put data somewhere else entirely.
    """
    explicit = os.environ.get("COCOINDEX_SQLITE_PATH")
    if explicit:
        return pathlib.Path(os.path.expanduser(explicit)).resolve()
    coco_db = os.environ.get("COCOINDEX_DB")
    if coco_db:
        root = pathlib.Path(os.path.expanduser(coco_db)).resolve()
        root.mkdir(parents=True, exist_ok=True)
        return root / "cocoindex_data.db"
    fallback = pathlib.Path(os.getcwd()) / "cocoindex_data.db"
    return fallback.resolve()


@coco.lifespan
def coco_lifespan(builder: coco.EnvironmentBuilder) -> AsyncIterator[None]:
    db_path = _resolve_sqlite_path()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite.connect(db_path, load_vec="auto")
    try:
        builder.provide(SQLITE_DB, conn)
        builder.provide(
            EMBEDDER,
            SentenceTransformerEmbedder(EMBED_MODEL, trust_remote_code=False),
        )
        yield
    finally:
        conn.close()


# ── LLM extraction (memoized) ────────────────────────────────────────────────

FUNC_PROMPT_TEMPLATE = """\
Analyze this {language} code. For each function/method defined in it, extract:
- name: function name
- signature: full signature line (no body)
- summary: one sentence of what it does
- calls: list of other function names it calls

Return ONLY valid JSON: [{{"name":"...","signature":"...","summary":"...","calls":["..."]}}]
If no functions, return [].

Code:
{code}
"""

FILE_PROMPT_TEMPLATE = """\
Analyze this {language} file ({filename}). Extract:
- purpose: one sentence describing what this file does
- exports: list of publicly exported names (functions, types, constants)
- depends_on: list of modules/packages it imports

Return ONLY valid JSON: {{"purpose":"...","exports":["..."],"depends_on":["..."]}}

File content:
{content}
"""


async def _litellm_json(prompt: str, max_tokens: int) -> dict | list | None:
    """Call LiteLLM with json_object response format; return parsed JSON."""
    try:
        import litellm  # imported lazily so missing dep only fails when invoked
    except ImportError:
        return None
    try:
        response = await litellm.acompletion(
            model=LITELLM_MODEL,
            messages=[{"role": "user", "content": prompt}],
            response_format={"type": "json_object"},
            max_tokens=max_tokens,
            timeout=LITELLM_TIMEOUT,
        )
    except Exception as exc:  # noqa: BLE001 — we swallow and degrade gracefully
        # Don't crash the indexer on a single LLM hiccup.
        print(f"[cocoindex_app_v1] litellm call failed: {exc!r}", file=sys.stderr)
        return None
    content = (response.choices[0].message.content or "").strip()
    if not content:
        return None
    try:
        return json.loads(content)
    except json.JSONDecodeError as exc:
        print(f"[cocoindex_app_v1] JSON parse failed: {exc} -- {content[:120]!r}",
              file=sys.stderr)
        return None


@coco.fn(memo=True)
async def extract_functions(code: str, language: str) -> list[dict]:
    """Extract per-function summaries from a single chunk.

    Memoized: same (code, language) won't trigger a re-call unless the code
    itself changes. Returns a list of dicts with ``name``, ``signature``,
    ``summary``, ``calls`` keys.
    """
    prompt = FUNC_PROMPT_TEMPLATE.format(
        language=language,
        code=code[:MAX_CHUNK_PROMPT_CHARS],
    )
    data = await _litellm_json(prompt, max_tokens=800)
    if not data:
        return []
    if isinstance(data, list):
        items = data
    elif isinstance(data, dict) and isinstance(data.get("functions"), list):
        items = data["functions"]
    else:
        return []
    out: list[dict] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        if not all(k in item for k in ("name", "signature", "summary", "calls")):
            continue
        if not isinstance(item["calls"], list):
            item["calls"] = []
        out.append(
            {
                "name": str(item["name"]),
                "signature": str(item["signature"]),
                "summary": str(item["summary"]),
                "calls": [str(c) for c in item["calls"]],
            }
        )
    return out


@coco.fn(memo=True)
async def summarize_file(content: str, language: str, filename: str) -> dict:
    """Extract a file-level purpose, exports, and dependency list."""
    prompt = FILE_PROMPT_TEMPLATE.format(
        language=language,
        filename=filename,
        content=content[:MAX_FILE_PROMPT_CHARS],
    )
    data = await _litellm_json(prompt, max_tokens=400)
    if not isinstance(data, dict):
        return {"purpose": "", "exports": [], "depends_on": []}
    return {
        "purpose": str(data.get("purpose", "")),
        "exports": [str(x) for x in data.get("exports", []) if x],
        "depends_on": [str(x) for x in data.get("depends_on", []) if x],
    }


# ── Per-file processing component ────────────────────────────────────────────

def _chunk_for_unsupported(text: str, chunk_size: int) -> list[Chunk]:
    """One single-chunk fallback for non-language files (defensive only)."""
    if not text:
        end_line = 1
    else:
        end_line = text.count("\n") + 1
    return [
        Chunk(
            text=text,
            start=TextPosition(byte_offset=0, char_offset=0, line=1, column=1),
            end=TextPosition(
                byte_offset=len(text.encode("utf-8", errors="replace")),
                char_offset=len(text),
                line=end_line,
                column=1,
            ),
        )
    ]


@coco.fn
async def process_file(
    file: FileLike,
    chunk_table: sqlite.TableTarget[ChunkEmbedding],
    func_table: sqlite.TableTarget[FuncSummary],
    file_table: sqlite.TableTarget[FileSummary],
) -> None:
    """Read one file, summarize it, embed its chunks, extract functions."""
    filename = str(file.file_path.path)
    text = await file.read_text(encoding="utf-8", errors="replace")
    language = detect_code_language(filename=filename) or "text"

    # ── File-level summary ────────────────────────────────────────────────────
    summary = await summarize_file(text, language, filename)
    file_id = IdGenerator()
    file_table.declare_row(
        row=FileSummary(
            id=await file_id.next_id(filename),
            filename=filename,
            language=language,
            purpose=summary["purpose"],
            exports_json=json.dumps(summary["exports"], ensure_ascii=False),
            depends_on_json=json.dumps(summary["depends_on"], ensure_ascii=False),
        )
    )

    # ── Chunks (tree-sitter syntax-aware) ─────────────────────────────────────
    if language != "text":
        try:
            ast = CodeAst(text, language)
            chunks = ast.split(CHUNK_SIZE, chunk_overlap=CHUNK_OVERLAP)
        except Exception as exc:  # noqa: BLE001 — fall back to single chunk
            print(f"[cocoindex_app_v1] CodeAst failed for {filename}: {exc!r}",
                  file=sys.stderr)
            chunks = _chunk_for_unsupported(text, CHUNK_SIZE)
    else:
        chunks = _chunk_for_unsupported(text, CHUNK_SIZE)
    if not chunks:
        chunks = _chunk_for_unsupported(text, CHUNK_SIZE)

    embedder = coco.use_context(EMBEDDER)
    chunk_id_gen = IdGenerator()
    func_id_gen = IdGenerator()

    for chunk in chunks:
        try:
            embedding = await embedder.embed(chunk.text)
        except Exception as exc:  # noqa: BLE001
            print(f"[cocoindex_app_v1] embed failed for {filename}: {exc!r}",
                  file=sys.stderr)
            continue

        chunk_table.declare_row(
            row=ChunkEmbedding(
                id=await chunk_id_gen.next_id(chunk.text),
                filename=filename,
                language=language,
                start_line=chunk.start.line,
                end_line=chunk.end.line,
                text=chunk.text,
                embedding=embedding,
            )
        )

        # Per-chunk function extraction
        functions = await extract_functions(chunk.text, language)
        for fn in functions:
            func_table.declare_row(
                row=FuncSummary(
                    id=await func_id_gen.next_id((filename, fn["name"], fn["signature"])),
                    filename=filename,
                    language=language,
                    func_name=fn["name"],
                    signature=fn["signature"],
                    summary=fn["summary"],
                    calls_json=json.dumps(fn["calls"], ensure_ascii=False),
                )
            )


# ── App entry point ───────────────────────────────────────────────────────────

@coco.fn
async def app_main() -> None:
    """Mount the three SQLite tables, then walk all configured source roots."""
    chunk_schema = await sqlite.TableSchema.from_class(
        ChunkEmbedding, primary_key=["id"]
    )
    func_schema = await sqlite.TableSchema.from_class(
        FuncSummary, primary_key=["id"]
    )
    file_schema = await sqlite.TableSchema.from_class(
        FileSummary, primary_key=["id"]
    )

    chunk_table = await sqlite.mount_table_target(
        SQLITE_DB, "chunk_embeddings", chunk_schema,
    )
    func_table = await sqlite.mount_table_target(
        SQLITE_DB, "func_summaries", func_schema,
    )
    file_table = await sqlite.mount_table_target(
        SQLITE_DB, "file_summaries", file_schema,
    )

    sources = _resolve_sources()
    included_patterns = [f"**/*{ext}" for ext in SUPPORTED_EXTENSIONS]
    excluded_patterns = [
        "**/.git/**",
        "**/node_modules/**",
        "**/__pycache__/**",
        "**/target/**",  # rust build
        "**/build/**",
        "**/dist/**",
        "**/.venv/**",
        "**/venv/**",
    ]

    for root in sources:
        if not root.exists():
            print(f"[cocoindex_app_v1] skip missing source root: {root}",
                  file=sys.stderr)
            continue
        matcher = PatternFilePathMatcher(
            included_patterns=included_patterns,
            excluded_patterns=excluded_patterns,
        )
        files = localfs.walk_dir(root, recursive=True, live=True, path_matcher=matcher)
        await coco.mount_each(process_file, files.items(), chunk_table, func_table, file_table)


app = coco.App(
    coco.AppConfig(name="CodeIndex", max_inflight_components=1024),
    app_main,
)