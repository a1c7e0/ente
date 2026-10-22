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

const file = (hash: string | undefined, updationTime = 100) =>
    ({ id: 42, updationTime, metadata: { hash, fileType: 1 } }) as EnteFile;

const box = { x: 0.1, y: 0.2, width: 0.3, height: 0.4 };

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

test("same source revision and box reuse the cached body crop", async () => {
    const first = await bodyCropBlob("body:42_1", file("hash-a"), box);
    const second = await bodyCropBlob("body:42_1", file("hash-a"), box);

    expect(second).toBe(first);
    expect(state.fetch).toHaveBeenCalledTimes(1);
    expect(createImageBitmap).toHaveBeenCalledTimes(1);
    expect(state.put).toHaveBeenCalledTimes(1);
});

test("legacy body ID cache entries are not used as a fallback", async () => {
    state.entries.set(
        "body:42_1",
        new Blob(["stale crop"], { type: "image/jpeg" }),
    );

    await expect(bodyCropBlob("body:42_1", file("hash-a"), box)).resolves.toBe(
        state.cropBlob,
    );

    expect(state.fetch).toHaveBeenCalledTimes(1);
    expect(state.put).toHaveBeenCalledTimes(1);
});

test("changed content with the same body ID recomputes its crop", async () => {
    const firstCrop = new Blob(["crop for source A"], { type: "image/jpeg" });
    const secondCrop = new Blob(["crop for source B"], { type: "image/jpeg" });
    state.cropBlob = firstCrop;
    const first = await bodyCropBlob("body:42_1", file("hash-a"), box);

    state.cropBlob = secondCrop;
    const second = await bodyCropBlob("body:42_1", file("hash-b"), box);

    expect(first).toBe(firstCrop);
    expect(second).toBe(secondCrop);
    expect(state.fetch).toHaveBeenCalledTimes(2);
    expect(createImageBitmap).toHaveBeenCalledTimes(2);
    expect(state.put).toHaveBeenCalledTimes(2);
});

test("files without a content hash use updation time as the revision", async () => {
    await bodyCropBlob("body:42_1", file(undefined, 100), box);
    await bodyCropBlob("body:42_1", file(undefined, 101), box);

    expect(state.fetch).toHaveBeenCalledTimes(2);
    expect(createImageBitmap).toHaveBeenCalledTimes(2);
});

test("different crop boxes do not reuse the same body crop", async () => {
    await bodyCropBlob("body:42_1", file("hash-a"), box);
    await bodyCropBlob("body:42_1", file("hash-a"), { ...box, x: 0.15 });

    expect(state.fetch).toHaveBeenCalledTimes(2);
    expect(createImageBitmap).toHaveBeenCalledTimes(2);
});

test("concurrent requests for the same revision share one crop decode", async () => {
    let resolveSource!: (source: Blob) => void;
    state.fetch.mockImplementation(
        () =>
            new Promise((resolve) => {
                resolveSource = resolve;
            }),
    );
    const first = bodyCropBlob("body:42_1", file("hash-a"), box);
    const second = bodyCropBlob("body:42_1", file("hash-a"), box);
    await vi.waitFor(() => expect(state.fetch).toHaveBeenCalledTimes(1));
    resolveSource(new Blob(["source"]));

    const [a, b] = await Promise.all([first, second]);
    expect(a).toBe(state.cropBlob);
    expect(b).toBe(state.cropBlob);
    expect(createImageBitmap).toHaveBeenCalledTimes(1);
    expect(state.put).toHaveBeenCalledTimes(1);
});

test("in-flight requests for old and new source revisions stay separate", async () => {
    const resolveSources: ((source: Blob) => void)[] = [];
    state.fetch.mockImplementation(
        () =>
            new Promise((resolve) => {
                resolveSources.push(resolve);
            }),
    );
    const oldCrop = new Blob(["old crop"], { type: "image/jpeg" });
    const newCrop = new Blob(["new crop"], { type: "image/jpeg" });

    const oldRequest = bodyCropBlob("body:42_1", file("hash-old"), box);
    await vi.waitFor(() => expect(resolveSources).toHaveLength(1));
    const newRequest = bodyCropBlob("body:42_1", file("hash-new"), box);
    await vi.waitFor(() => expect(resolveSources).toHaveLength(2));

    state.cropBlob = newCrop;
    resolveSources[1](new Blob(["new source"]));
    await expect(newRequest).resolves.toBe(newCrop);

    state.cropBlob = oldCrop;
    resolveSources[0](new Blob(["old source"]));
    await expect(oldRequest).resolves.toBe(oldCrop);

    expect(state.fetch).toHaveBeenCalledTimes(2);
    expect(createImageBitmap).toHaveBeenCalledTimes(2);
    expect(state.put).toHaveBeenCalledTimes(2);
    expect(new Set(state.put.mock.calls.map(([key]) => key)).size).toBe(2);
});

test("failed body crop is not cached and can be retried", async () => {
    state.fetch
        .mockRejectedValueOnce(new Error("temporary download failure"))
        .mockResolvedValueOnce(new Blob(["source"]));

    await expect(
        bodyCropBlob("body:42_1", file("hash-a"), box),
    ).rejects.toThrow("temporary download failure");
    expect(state.put).not.toHaveBeenCalled();

    await expect(bodyCropBlob("body:42_1", file("hash-a"), box)).resolves.toBe(
        state.cropBlob,
    );
    expect(state.fetch).toHaveBeenCalledTimes(2);
    expect(createImageBitmap).toHaveBeenCalledTimes(1);
    expect(state.put).toHaveBeenCalledTimes(1);
});
