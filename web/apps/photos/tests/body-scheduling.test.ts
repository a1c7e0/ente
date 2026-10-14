import { readNextIndexableFileIDs } from "ente-new/photos/services/ml/db";
import { beforeEach, expect, test, vi } from "vitest";

const state = vi.hoisted(() => ({
    statuses: [] as { fileID: number; status: string; failureCount: number }[],
}));

vi.mock("ente-base/log", () => ({ default: { info: vi.fn() } }));
vi.mock("idb", () => {
    const db = {
        transaction: () => ({
            store: {
                index: () => ({
                    openKeyCursor: (status: string) => {
                        const ids = state.statuses
                            .filter((s) => s.status == status)
                            .map((s) => s.fileID)
                            .sort((a, b) => b - a);
                        interface Cursor {
                            primaryKey: number;
                            continue: () => Promise<Cursor | null>;
                        }
                        const cursor = (i: number): Cursor | null =>
                            i < ids.length
                                ? {
                                      primaryKey: ids[i]!,
                                      continue: () =>
                                          Promise.resolve(cursor(i + 1)),
                                  }
                                : null;
                        return Promise.resolve(cursor(0));
                    },
                }),
            },
        }),
        // Completed photos intentionally have no body rows. Reintroducing
        // the historical backfill path would make these tests return them.
        getAllKeys: () => Promise.resolve([]),
        getAllFromIndex: (_store: string, _index: string, status: string) =>
            Promise.resolve(state.statuses.filter((s) => s.status == status)),
    };
    return { openDB: () => Promise.resolve(db) };
});

beforeEach(() => {
    state.statuses = [];
    vi.stubGlobal("IDBKeyRange", { only: (value: string) => value });
});

test("completed photos missing body data do not enter the indexing queue", async () => {
    state.statuses = [{ fileID: 1, status: "indexed", failureCount: 0 }];
    expect(await readNextIndexableFileIDs(100)).toEqual([]);
});

test("normal indexing retains its order and limit without filling spare slots with old photos", async () => {
    state.statuses = [
        { fileID: 1, status: "indexed", failureCount: 0 },
        { fileID: 2, status: "indexable", failureCount: 0 },
        { fileID: 3, status: "indexable", failureCount: 0 },
    ];
    expect(await readNextIndexableFileIDs(1)).toEqual([3]);
    expect(await readNextIndexableFileIDs(100)).toEqual([3, 2]);
});
