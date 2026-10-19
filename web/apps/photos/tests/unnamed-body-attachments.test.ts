import type { EnteFile } from "ente-media/file";
import type { FaceCluster } from "ente-new/photos/services/ml/cluster";
import { reconstructPeopleState } from "ente-new/photos/services/ml/people";
import { beforeEach, expect, test, vi } from "vitest";

const state = vi.hoisted(() => ({
    files: [] as EnteFile[],
    clusters: [] as FaceCluster[],
    matches: [] as {
        fileID: number;
        detection: { bodyID: string };
        personID: string;
        similarity: number;
        margin: number;
    }[],
    faceIndexes: [] as { faces: { faceID: string; score: number }[] }[],
}));

vi.mock("ente-base/log", () => ({
    default: { info: vi.fn(), debug: vi.fn(), warn: vi.fn(), error: vi.fn() },
}));
vi.mock("ente-media/file-metadata", () => ({
    fileCreationPhotoSortTime: (file: EnteFile) => file.metadata.creationTime,
}));
vi.mock("ente-new/photos/services/file", () => ({
    computeNormalCollectionFilesFromSaved: () => Promise.resolve(state.files),
}));
vi.mock("ente-new/photos/services/user-entity", () => ({
    savedCGroups: () => Promise.resolve([]),
    updateOrCreateUserEntities: vi.fn(),
    pullUserEntities: vi.fn(),
}));
vi.mock("ente-new/photos/services/ml/body", () => ({
    isAutomaticBodyMatch: (match: (typeof state.matches)[number]) =>
        match.similarity >= 0.74 && match.margin >= 0.05,
    isBodyReference: (id: string) =>
        id.startsWith("body:") || id.startsWith("body-group:"),
}));
vi.mock("ente-new/photos/services/ml/body-review", () => ({
    currentBodyMatches: () => Promise.resolve(state.matches),
    bodyChoicesForPerson: vi.fn(),
    bodyGroupWithID: vi.fn(),
    bodySuggestionsForPerson: vi.fn(),
    updateBodyDecision: vi.fn(),
}));
vi.mock("ente-new/photos/services/ml/db", () => ({
    savedFaceClusters: () => Promise.resolve(state.clusters),
    savedFaceIndexes: () => Promise.resolve(state.faceIndexes),
    saveFaceClusters: vi.fn(),
}));
vi.mock("ente-new/photos/services/ml/face", () => ({
    fileIDFromFaceID: (faceID: string) => Number(faceID.split("_")[0]),
}));
vi.mock("ente-new/photos/services/ml/kvdb", () => ({
    savedRejectedClustersForCGroup: () => Promise.resolve([]),
    saveRejectedClustersForCGroup: vi.fn(),
}));
vi.mock("ente-new/photos/services/ml/math", () => ({ dotProduct: vi.fn() }));

beforeEach(() => {
    state.files = Array.from(
        { length: 11 },
        (_, i) =>
            ({ id: i + 1, metadata: { creationTime: i + 1 } }) as EnteFile,
    );
    state.clusters = [
        {
            id: "face-cluster",
            faces: Array.from({ length: 10 }, (_, i) => `${i + 1}_face`),
        },
    ];
    state.faceIndexes = [
        {
            faces: Array.from({ length: 10 }, (_, i) => ({
                faceID: `${i + 1}_face`,
                score: 0.9,
            })),
        },
    ];
    state.matches = [
        {
            fileID: 11,
            detection: { bodyID: "body:11_1" },
            personID: "cluster:face-cluster",
            similarity: 0.8,
            margin: 0.1,
        },
    ];
});

test("high-confidence body matches add files to the existing unnamed cluster", async () => {
    const stateResult = await reconstructPeopleState();

    expect(stateResult.people).toHaveLength(1);
    expect(stateResult.people[0]).toMatchObject({
        type: "cluster",
        id: "face-cluster",
    });
    expect(stateResult.people[0]!.fileIDs).toHaveLength(11);
    expect(stateResult.people[0]!.fileIDs).toEqual(
        expect.arrayContaining([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]),
    );
    expect(stateResult.visiblePeople.map((person) => person.id)).toEqual([
        "face-cluster",
    ]);
});

test("low-confidence body matches do not affect unnamed-cluster counts", async () => {
    state.matches[0]!.margin = 0.01;

    const stateResult = await reconstructPeopleState();

    expect(stateResult.people[0]!.fileIDs).toHaveLength(10);
});

test("body attachments do not satisfy the face-count visibility threshold", async () => {
    state.clusters[0]!.faces = state.clusters[0]!.faces.slice(0, 9);
    state.faceIndexes[0]!.faces = state.faceIndexes[0]!.faces.slice(0, 9);

    const stateResult = await reconstructPeopleState();

    expect(stateResult.people[0]!.fileIDs).toHaveLength(10);
    expect(stateResult.visiblePeople).toEqual([]);
});
