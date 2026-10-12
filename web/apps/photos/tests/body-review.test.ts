import { HTTPError } from "ente-base/http";
import type { EnteFile } from "ente-media/file";
import {
    bodyModel,
    type LocalBodyIndex,
} from "ente-new/photos/services/ml/body";
import { _applyPersonSuggestionUpdates } from "ente-new/photos/services/ml/people";
import type { CGroup } from "ente-new/photos/services/user-entity";
import { beforeEach, expect, test, vi } from "vitest";

const state = vi.hoisted(() => {
    const raw: Record<string, unknown> = {};
    return {
        index: undefined as LocalBodyIndex | undefined,
        group: undefined as CGroup | undefined,
        raw,
        updatedAt: 10,
        write: vi.fn<
            (
                file: EnteFile,
                raw: Record<string, unknown>,
                updatedAt: number,
            ) => Promise<void>
        >(),
        entityWrite:
            vi.fn<
                (type: string, groups: CGroup[], key: string) => Promise<void>
            >(),
        faceFeedbackWrite:
            vi.fn<(personID: string, clusterIDs: string[]) => Promise<void>>(),
    };
});

vi.mock("ente-base/log", () => ({
    default: { info: vi.fn(), debug: vi.fn(), warn: vi.fn(), error: vi.fn() },
}));
vi.mock("ente-new/photos/services/file", () => ({
    computeNormalCollectionFilesFromSaved: () =>
        Promise.resolve([{ id: 2 } as EnteFile]),
}));
vi.mock("ente-new/photos/services/user-entity", () => ({
    savedCGroups: () => Promise.resolve([state.group!]),
    updateOrCreateUserEntities: (type: string, groups: CGroup[], key: string) =>
        state.entityWrite(type, groups, key),
}));
vi.mock("ente-new/photos/services/ml/kvdb", () => ({
    savedRejectedClustersForCGroup: () => Promise.resolve([]),
    saveRejectedClustersForCGroup: (personID: string, clusterIDs: string[]) =>
        state.faceFeedbackWrite(personID, clusterIDs),
}));
vi.mock("ente-new/photos/services/ml/db", () => ({
    savedBodyIndexes: () => Promise.resolve([state.index!]),
    saveBodyIndex: (index: LocalBodyIndex) => {
        state.index = index;
        return Promise.resolve(index.fileID);
    },
    savedFaceIndexes: () => Promise.resolve([]),
    savedFaceClusters: () =>
        Promise.resolve([{ id: "normal-cluster", faces: ["2_face"] }]),
    saveFaceClusters: vi.fn(),
}));
vi.mock("ente-new/photos/services/ml/ml-data", () => ({
    fetchMLData: () =>
        Promise.resolve(
            new Map([
                [
                    2,
                    {
                        raw: state.raw,
                        parsed: undefined,
                        updatedAt: state.updatedAt,
                    },
                ],
            ]),
        ),
    putMLData: (
        file: EnteFile,
        raw: Record<string, unknown>,
        updatedAt: number,
    ) => state.write(file, raw, updatedAt),
}));

beforeEach(() => {
    vi.clearAllMocks();
    state.index = {
        fileID: 2,
        version: 1,
        model: bodyModel,
        client: "test",
        width: 1000,
        height: 1000,
        detections: [
            {
                bodyID: "body:2_1",
                box: { x: 0.1, y: 0.1, width: 0.3, height: 0.7 },
                score: 0.9,
                linkedFaceID: null,
                embedding: [1, ...Array<number>(511).fill(0)],
                decisions: {},
                futureDetectionField: "retain",
            },
        ],
    };
    state.group = {
        id: "person-a",
        updatedAt: 1,
        data: {
            name: "A",
            assigned: [{ id: "anchor", faces: ["1_face"] }],
            rejectedFaceIDs: [],
            manuallyAssigned: [],
            isHidden: false,
        },
    };
    state.raw = {
        face: { unchanged: true },
        clip: { unchanged: true },
        futureSubtype: { keep: true },
        body: state.index,
    };
    state.updatedAt = 10;
    state.write.mockImplementation(
        (_file: EnteFile, raw: Record<string, unknown>) => {
            state.raw = raw;
            state.updatedAt++;
            return Promise.resolve();
        },
    );
    state.entityWrite.mockImplementation((_type: string, groups: CGroup[]) => {
        state.group = groups[0];
        return Promise.resolve();
    });
});

test("body confirmation uses manual photo assignments and never merges into face clusters", async () => {
    await _applyPersonSuggestionUpdates(
        state.group!,
        new Map([["body:2_1", "assign"]]),
        "key",
    );
    expect(state.group!.data.manuallyAssigned).toEqual([2]);
    expect(state.group!.data.assigned).toEqual([
        { id: "anchor", faces: ["1_face"] },
    ]);
    expect(state.index!.detections[0]!.decisions["person-a"]).toEqual({
        status: "accepted",
        addedManual: true,
    });
    expect(state.raw.face).toEqual({ unchanged: true });
    expect(state.raw.clip).toEqual({ unchanged: true });
    expect(state.raw.futureSubtype).toEqual({ keep: true });
    expect(state.index!.detections[0]!.futureDetectionField).toBe("retain");
});

test("reset removes only the photo assignment created by this confirmation", async () => {
    await _applyPersonSuggestionUpdates(
        state.group!,
        new Map([["body:2_1", "assign"]]),
        "key",
    );
    await _applyPersonSuggestionUpdates(
        state.group!,
        new Map([["body:2_1", "reset"]]),
        "key",
    );
    expect(state.group!.data.manuallyAssigned).toEqual([]);
    expect(state.index!.detections[0]!.decisions).toEqual({});
    state.group!.data.manuallyAssigned = [2];
    await _applyPersonSuggestionUpdates(
        state.group!,
        new Map([["body:2_1", "assign"]]),
        "key",
    );
    await _applyPersonSuggestionUpdates(
        state.group!,
        new Map([["body:2_1", "reset"]]),
        "key",
    );
    expect(state.group!.data.manuallyAssigned).toEqual([2]);
});

test("body rejection is separate from face rejection and can be reopened", async () => {
    await _applyPersonSuggestionUpdates(
        state.group!,
        new Map([["body:2_1", "rejectSuggestion"]]),
        "key",
    );
    expect(state.index!.detections[0]!.decisions["person-a"]!.status).toBe(
        "rejected",
    );
    expect(state.faceFeedbackWrite).not.toHaveBeenCalled();
    expect(state.group!.data.rejectedFaceIDs).toEqual([]);
    await _applyPersonSuggestionUpdates(
        state.group!,
        new Map([["body:2_1", "reset"]]),
        "key",
    );
    expect(state.index!.detections[0]!.decisions).toEqual({});
});

test("body writes refetch after a conflict and retain concurrent unknown fields", async () => {
    state.write.mockImplementationOnce(() => {
        state.raw = { ...state.raw, concurrentField: "keep" };
        state.updatedAt = 20;
        throw new HTTPError({
            url: "https://example.test/files/data",
            status: 409,
            statusText: "Conflict",
            headers: new Headers(),
        } as Response);
    });
    await _applyPersonSuggestionUpdates(
        state.group!,
        new Map([["body:2_1", "assign"]]),
        "key",
    );
    expect(state.write).toHaveBeenCalledTimes(2);
    expect(state.write.mock.calls[1]![2]).toBe(20);
    expect(state.raw.concurrentField).toBe("keep");
});

test("original face-cluster assignment continues to use the original path", async () => {
    await _applyPersonSuggestionUpdates(
        state.group!,
        new Map([["normal-cluster", "assign"]]),
        "key",
    );
    expect(state.group!.data.assigned).toEqual([
        { id: "anchor", faces: ["1_face"] },
        { id: "normal-cluster", faces: ["2_face"] },
    ]);
    expect(state.group!.data.manuallyAssigned).toEqual([]);
    expect(state.write).not.toHaveBeenCalled();
});
