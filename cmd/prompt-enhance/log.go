package main

import (
	"context"
	"log/slog"
	"os"
	"time"
)

var logger = slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))

type traceKey struct{}

func traceEnter(ctx context.Context, fn string, fields ...slog.Attr) context.Context {
	attrs := []slog.Attr{slog.String("fn", fn), slog.String("event", "enter")}
	attrs = append(attrs, fields...)
	logger.LogAttrs(ctx, slog.LevelDebug, "trace", attrs...)
	start := time.Now()
	return context.WithValue(ctx, traceKey{}, start)
}

func traceExit(ctx context.Context, fn string) {
	start, ok := ctx.Value(traceKey{}).(time.Time)
	if !ok {
		return
	}
	attrs := []slog.Attr{
		slog.String("fn", fn),
		slog.String("event", "exit"),
		slog.Duration("duration", time.Since(start)),
	}
	logger.LogAttrs(ctx, slog.LevelDebug, "trace", attrs...)
}

func logError(ctx context.Context, fn string, err error, fields ...slog.Attr) {
	attrs := []slog.Attr{slog.String("fn", fn), slog.String("error", err.Error())}
	attrs = append(attrs, fields...)
	logger.LogAttrs(ctx, slog.LevelError, "error", attrs...)
}

func logInfo(ctx context.Context, fn string, msg string, fields ...slog.Attr) {
	attrs := []slog.Attr{slog.String("fn", fn)}
	attrs = append(attrs, fields...)
	logger.LogAttrs(ctx, slog.LevelInfo, msg, attrs...)
}

func logWarn(ctx context.Context, fn string, msg string, fields ...slog.Attr) {
	attrs := []slog.Attr{slog.String("fn", fn)}
	attrs = append(attrs, fields...)
	logger.LogAttrs(ctx, slog.LevelWarn, msg, attrs...)
}

func logDebug(ctx context.Context, fn string, msg string, fields ...slog.Attr) {
	attrs := []slog.Attr{slog.String("fn", fn)}
	attrs = append(attrs, fields...)
	logger.LogAttrs(ctx, slog.LevelDebug, msg, attrs...)
}
