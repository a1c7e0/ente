import type { EnteFile } from "ente-media/file";
import {
    BodyIndex,
    bodyEmbeddingPrecision,
    bodyIndexingVersion,
    bodyModel,
    compactBodyIndex,
    isAutomaticBodyMatch,
    linkBodyFaces,
    matchBodies,
    type BodyDetection,
    type LocalBodyIndex,
} from "ente-new/photos/services/ml/body";
import { describe, expect, test } from "vitest";

const vector = (cosine = 1) => [
    cosine,
    Math.sqrt(1 - cosine ** 2),
    ...Array<number>(510).fill(0),
];
const detection = (
    bodyID: string,
    linkedFaceID: string | null = null,
    embedding = vector(),
): BodyDetection => ({
    bodyID,
    linkedFaceID,
    box: { x: 0.1, y: 0.1, width: 0.3, height: 0.7 },
    score: 0.9,
    embedding,
    decisions: {},
});
const index = (
    fileID: number,
    detections: BodyDetection[],
): LocalBodyIndex => ({
    fileID,
    version: bodyIndexingVersion,
    model: bodyModel,
    client: "test",
    width: 1000,
    height: 1000,
    detections,
});
const file = (id: number, seconds = 0) =>
    ({
        id,
        metadata: { creationTime: 1_700_000_000_000_000 + seconds * 1e6 },
    }) as EnteFile;

describe("body evidence", () => {
    test("compacts vectors while retaining the existing numeric array shape", () => {
        const source = index(1, [
            detection("body:1_1", null, [
                0.12345678,
                -0.00789123,
                ...Array<number>(510).fill(0),
            ]),
        ]);
        const compact = compactBodyIndex(source);

        expect(compact.embeddingPrecision).toBe(bodyEmbeddingPrecision);
        expect(compact.detections[0]!.embedding).toEqual([
            0.1235,
            -0.007891,
            ...Array<number>(510).fill(0),
        ]);
        expect(BodyIndex.safeParse(compact).success).toBe(true);
    });

    test("stable unnamed-cluster rejections survive naming and retain rival scores", () => {
        const rejected = {
            ...detection("body:3_1"),
            rejectedAnchorFaceIDs: ["1_face"],
        };
        const indexes = [
            index(1, [detection("body:1_1", "1_face")]),
            index(2, [detection("body:2_1", "2_face", vector(0.9))]),
            index(3, [rejected]),
        ];
        for (const identity of ["cluster:unnamed", "named-person"]) {
            expect(
                matchBodies(
                    indexes,
                    [file(1), file(2), file(3)],
                    new Map([
                        ["1_face", identity],
                        ["2_face", "another-person"],
                    ]),
                ),
            ).toEqual([]);
        }
        expect(
            BodyIndex.safeParse({
                ...index(3, [rejected]),
                detections: [{ ...rejected, rejectedAnchorFaceIDs: [42] }],
            }).success,
        ).toBe(false);
    });

    test("attaches a back view to a face-anchored person inside three hours", () => {
        const matches = matchBodies(
            [
                index(1, [detection("body:1_1", "1_face")]),
                index(2, [detection("body:2_1")]),
            ],
            [file(1), file(2, 100)],
            new Map([["1_face", "person-a"]]),
        );
        expect(matches).toHaveLength(1);
        expect(matches[0]!.personID).toBe("person-a");
        expect(isAutomaticBodyMatch(matches[0]!)).toBe(true);
    });

    test("does not link across a capture-time gap or unknown timestamps", () => {
        const indexes = [
            index(1, [detection("body:1_1", "1_face")]),
            index(2, [detection("body:2_1")]),
        ];
        const persons = new Map([["1_face", "person-a"]]);
        expect(
            matchBodies(indexes, [file(1), file(2, 10801)], persons),
        ).toEqual([]);
        expect(
            matchBodies(
                indexes,
                [
                    file(1),
                    { ...file(2), metadata: { creationTime: 0 } } as EnteFile,
                ],
                persons,
            ),
        ).toEqual([]);
    });

    test("keeps the runner-up in the margin even when rejected", () => {
        const body = detection("body:3_1");
        const indexes = [
            index(1, [detection("body:1_1", "1_face")]),
            index(2, [detection("body:2_1", "2_face", vector(0.98))]),
            index(3, [body]),
        ];
        body.decisions["person-b"] = { status: "rejected" };
        const matches = matchBodies(
            indexes,
            [file(1), file(2), file(3)],
            new Map([
                ["1_face", "person-a"],
                ["2_face", "person-b"],
            ]),
        );
        expect(matches).toHaveLength(1);
        expect(isAutomaticBodyMatch(matches[0]!)).toBe(false);
        body.decisions["person-a"] = { status: "rejected" };
        expect(
            matchBodies(
                indexes,
                [file(1), file(2), file(3)],
                new Map([
                    ["1_face", "person-a"],
                    ["2_face", "person-b"],
                ]),
            ),
        ).toEqual([]);
    });

    test("a person cannot receive another body in a photo containing their face", () => {
        expect(
            matchBodies(
                [
                    index(1, [detection("body:1_1", "1_face")]),
                    index(2, [detection("body:2_1")]),
                ],
                [file(1), file(2)],
                new Map([
                    ["1_face", "person-a"],
                    ["2_other", "person-a"],
                ]),
            ),
        ).toEqual([]);
    });

    test("a prior confirmation prevents automatic reassignment after its person is removed", () => {
        const body = detection("body:2_1");
        body.decisions["removed-person"] = { status: "accepted" };
        expect(
            matchBodies(
                [index(1, [detection("body:1_1", "1_face")]), index(2, [body])],
                [file(1), file(2)],
                new Map([["1_face", "person-a"]]),
            ),
        ).toEqual([]);
    });

    test("parses empty results and preserves extension keys without accepting another vector space", () => {
        const raw = { ...index(1, []), extra: { future: true } };
        expect(BodyIndex.parse(raw).extra).toEqual({ future: true });
        expect(
            BodyIndex.safeParse({ ...raw, model: "other-model" }).success,
        ).toBe(false);
        expect(
            BodyIndex.safeParse({
                ...raw,
                detections: [{ ...detection("body:1_1"), embedding: [1] }],
            }).success,
        ).toBe(false);
    });

    test("face links are geometric and do not reuse a face for two bodies", () => {
        const face = {
            faceID: "1_face",
            detection: {
                box: { x: 0.2, y: 0.15, width: 0.1, height: 0.1 },
                landmarks: [],
            },
            score: 0.9,
            blur: 100,
            embedding: [],
        };
        const bodies = linkBodyFaces(
            [1, 2].map((n) => ({
                bodyId: `body:1_${n}`,
                boxXyxy: [0.1, 0.1, 0.5, 0.9],
                score: 0.9,
                embedding: vector(),
            })),
            [face],
        );
        expect(bodies.map((b) => b.linkedFaceID)).toEqual(["1_face", null]);
        expect(
            linkBodyFaces(
                [
                    {
                        bodyId: "body:1_1",
                        boxXyxy: [0.1, 0.1, 0.5, 0.9],
                        score: 0.9,
                        embedding: vector(),
                    },
                ],
                [face, { ...face, faceID: "1_other" }],
            ),
        ).toEqual([]);
    });
});
