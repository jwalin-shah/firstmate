"""CocoIndex app — indexes this project using .cocoindex_code/settings.yml."""
from __future__ import annotations

import importlib
import pathlib

import cocoindex as coco
from cocoindex.connectors import sqlite as coco_sqlite
from cocoindex_code.chunking import CHUNKER_REGISTRY
from cocoindex_code.embedder_params import resolve_embedder_params
from cocoindex_code.indexer import indexer_main
from cocoindex_code.settings import (
    cocoindex_db_path,
    load_project_settings,
    load_user_settings,
    resolve_db_dir,
    target_sqlite_db_path,
)
from cocoindex_code.shared import (
    CODEBASE_DIR,
    EMBEDDER,
    INDEXING_EMBED_PARAMS,
    QUERY_EMBED_PARAMS,
    SQLITE_DB,
    create_embedder,
)

PROJECT_ROOT = pathlib.Path(__file__).parent.parent.resolve()

_user_settings = load_user_settings()
_project_settings = load_project_settings(PROJECT_ROOT)
_params = resolve_embedder_params(_user_settings.embedding)
_embedder = create_embedder(_user_settings.embedding, _params.indexing or None)

resolve_db_dir(PROJECT_ROOT).mkdir(parents=True, exist_ok=True)

_chunker_registry: dict = {}
for _cm in _project_settings.chunkers:
    _module_path, _, _attr = _cm.module.partition(":")
    _mod = importlib.import_module(_module_path)
    _chunker_registry[f".{_cm.ext}"] = getattr(_mod, _attr)

_context = coco.ContextProvider()
_context.provide(CODEBASE_DIR, PROJECT_ROOT)
_context.provide(SQLITE_DB, coco_sqlite.connect(str(target_sqlite_db_path(PROJECT_ROOT)), load_vec=True))
_context.provide(EMBEDDER, _embedder)
_context.provide(INDEXING_EMBED_PARAMS, dict(_params.indexing))
_context.provide(QUERY_EMBED_PARAMS, dict(_params.query))
_context.provide(CHUNKER_REGISTRY, _chunker_registry)

_env = coco.Environment(
    coco.Settings.from_env(cocoindex_db_path(PROJECT_ROOT)),
    context_provider=_context,
)

app = coco.App(
    coco.AppConfig(name="CocoIndexCode", environment=_env),
    indexer_main,
)

