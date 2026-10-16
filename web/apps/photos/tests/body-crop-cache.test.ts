import type { EnteFile } from "ente-media/file";
import { bodyCropBlob } from "ente-new/photos/services/ml/crop";
import { beforeEach, expect, test, vi } from "vitest";

const state = vi.hoisted(() => {
    const entries = new Map<string, Blob>();
    return {
        entries,
        get: vi.fn(async (key: string) => entries.get(key)),
        put: vi.fn(async (key: string, blob: Blob) => {
            entries.set(key, blob);
        }),
        fetch: vi.fn<(...args: unknown[]) => Promise<Blob>>(),
        cropBlob: new Blob(["body crop"], { type: "image/jpeg" }),
    };
});

vi.mock("ente-base/blob-cache", () => ({
    blobCache: () => Promise.resolve({ get: state.get, put: state.put }),
}));
vi.mock("ente-new/photos/services/ml/blob", () => ({
    fetchRenderableEnteFileBlob: state.fetch,
}));

beforeEach(() => {
    vi.clearAllMocks();
    state.entries.clear();
    state.cropBlob = new Blob(["body crop"], { type: "image/jpeg" });
    const bitmap = {
        width: 640,
        height: 480,
        close: vi.fn(),
    } as unknown as ImageBitmap;
    vi.stubGlobal(
        "createImageBitmap",
        vi.fn(async () => bitmap),
    );
    vi.stubGlobal(
        "OffscreenCanvas",
        class {
            getContext() {
                return { imageSmoothingQuality: "high", drawImage: vi.fn() };
            }

            convertToBlob() {
                return Promise.resolve(state.cropBlob);
            }
        },
    );
    state.fetch.mockResolvedValue(new Blob(["source"]));
});

test("body crop blob cache hit skips source fetch and decode", async () => {
    const cached = new Blob(["cached crop"], { type: "image/jpeg" });
    state.entries.set("body:42_1", cached);

    await expect(
        bodyCropBlob("body:42_1", { id: 42 } as EnteFile, {
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.4,
        }),
    ).resolves.toBe(cached);

    expect(state.fetch).not.toHaveBeenCalled();
    expect(createImageBitmap).not.toHaveBeenCalled();
});

test("concurrent requests share one body crop decode and cache write", async () => {
    let resolveSource!: (source: Blob) => void;
    state.fetch.mockImplementation(
        () =>
            new Promise((resolve) => {
                resolveSource = resolve;
            }),
    );
    const file = { id: 42 } as EnteFile;
    const box = { x: 0.1, y: 0.2, width: 0.3, height: 0.4 };

    const first = bodyCropBlob("body:42_1", file, box);
    const second = bodyCropBlob("body:42_1", file, box);
    await vi.waitFor(() => expect(state.fetch).toHaveBeenCalledTimes(1));
    resolveSource(new Blob(["source"]));

    const [a, b] = await Promise.all([first, second]);
    expect(a).toBe(state.cropBlob);
    expect(b).toBe(state.cropBlob);
    expect(createImageBitmap).toHaveBeenCalledTimes(1);
    expect(state.put).toHaveBeenCalledTimes(1);
});

test("failed body crop is not cached and can be retried", async () => {
    state.fetch
        .mockRejectedValueOnce(new Error("temporary download failure"))
        .mockResolvedValueOnce(new Blob(["source"]));
    const file = { id: 42 } as EnteFile;
    const box = { x: 0.1, y: 0.2, width: 0.3, height: 0.4 };

    await expect(bodyCropBlob("body:42_1", file, box)).rejects.toThrow(
        "temporary download failure",
    );
    expect(state.put).not.toHaveBeenCalled();

    await expect(bodyCropBlob("body:42_1", file, box)).resolves.toBe(
        state.cropBlob,
    );
    expect(state.fetch).toHaveBeenCalledTimes(2);
    expect(createImageBitmap).toHaveBeenCalledTimes(1);
    expect(state.put).toHaveBeenCalledTimes(1);
});
