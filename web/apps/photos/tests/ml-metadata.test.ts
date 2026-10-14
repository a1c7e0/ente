import { HTTPError } from "ente-base/http";
import {
    faceDetectionModel,
    faceEmbeddingModel,
} from "ente-new/photos/services/ml/face";
import { mergeMetadata } from "ente-new/photos/services/ml/metadata-update";
import { remoteMLDataFromJSONString } from "ente-new/photos/services/ml/ml-data";
import { expect, test } from "vitest";

test("legacy face metadata defaults to the current models without rewriting raw data", () => {
    const raw = {
        face: {
            version: 1,
            client: "legacy",
            width: 100,
            height: 100,
            faces: [],
            future: 7,
        },
    };
    const parsed = remoteMLDataFromJSONString(JSON.stringify(raw), 10);
    expect(parsed.parsed?.face?.model).toBe(faceEmbeddingModel);
    expect(parsed.parsed?.face?.detectorModel).toBe(faceDetectionModel);
    expect(parsed.raw).toEqual(raw);
    const withNull = remoteMLDataFromJSONString(
        JSON.stringify({ face: { ...raw.face, model: null } }),
        10,
    );
    expect(withNull.parsed?.face?.model).toBe(faceEmbeddingModel);
});

test("model identifiers from newer face metadata survive parsing", () => {
    const parsed = remoteMLDataFromJSONString(
        JSON.stringify({
            face: {
                version: 1,
                client: "future",
                width: 100,
                height: 100,
                faces: [],
                model: "new-model-v2",
                detectorModel: "new-detector-v2",
            },
        }),
        10,
    );
    expect(parsed.parsed?.face?.model).toBe("new-model-v2");
});

test("face updates retry against the newest body review and unknown fields", async () => {
    let data = { face: { value: "old" }, body: { review: "old" }, future: 7 };
    let stamp = 10;
    const writes: number[] = [];
    const updated = await mergeMetadata(
        () =>
            Promise.resolve({ data: structuredClone(data), updatedAt: stamp }),
        (next, updatedAt) => {
            writes.push(updatedAt);
            if (writes.length == 1) {
                data.body.review = "another-device";
                stamp = 20;
                return Promise.reject(
                    new HTTPError({
                        url: "https://example.test/files/data",
                        status: 409,
                        statusText: "Conflict",
                        headers: new Headers(),
                    } as Response),
                );
            }
            data = next;
            return Promise.resolve();
        },
        (latest) => {
            latest.face.value = "new";
        },
    );
    expect(writes).toEqual([10, 20]);
    expect(updated).toEqual({
        face: { value: "new" },
        body: { review: "another-device" },
        future: 7,
    });
});
