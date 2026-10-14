import type { EnteFile } from "ente-media/file";
import {
    groupBodyMatches,
    type BodyMatch,
} from "ente-new/photos/services/ml/body";
import { expect, test } from "vitest";

const match = (id: number, cosine = 1, partition?: string): BodyMatch => ({
    fileID: id,
    personID: "person-a",
    similarity: 0.8,
    margin: 0.1,
    detection: {
        bodyID: `body:${id}_1`,
        box: { x: 0, y: 0, width: 0.5, height: 0.8 },
        score: 0.9,
        embedding: [
            cosine,
            Math.sqrt(1 - cosine * cosine),
            ...Array<number>(510).fill(0),
        ],
        decisions: {},
        groupID: partition,
    },
});
const files = [1, 2, 3].map(
    (id) => ({ id, metadata: { creationTime: 1700000000000000 } }) as EnteFile,
);

test("similar bodies form one stable review group regardless of input order", () => {
    const groups = groupBodyMatches([match(3), match(1), match(2)], files);
    expect(groups).toHaveLength(1);
    expect(groups[0]!.id).toBe("body-group:1_1");
    expect(groups[0]!.matches.map((m) => m.fileID)).toEqual([1, 2, 3]);
});

test("a similarity chain cannot join dissimilar endpoints", () => {
    const groups = groupBodyMatches(
        [match(1), match(2, 0.85), match(3, 0.55)],
        files,
    );
    expect(groups.map((g) => g.matches.length)).toEqual([2, 1]);
});

test("human split boundaries, different people, same-photo bodies and capture gaps remain separate", () => {
    expect(
        groupBodyMatches(
            [match(1, 1, "body-group:a"), match(2, 1, "body-group:b")],
            files,
        ),
    ).toHaveLength(2);
    expect(
        groupBodyMatches(
            [match(1), { ...match(2), personID: "person-b" }],
            files,
        ),
    ).toHaveLength(2);
    expect(
        groupBodyMatches([match(1), { ...match(2), fileID: 1 }], files),
    ).toHaveLength(2);
    expect(
        groupBodyMatches(
            [match(1), match(2)],
            [
                files[0]!,
                {
                    id: 2,
                    metadata: { creationTime: 1700000000000000 + 10801000000 },
                } as EnteFile,
            ],
        ),
    ).toHaveLength(2);
});
