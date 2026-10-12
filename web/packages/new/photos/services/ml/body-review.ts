import { isHTTPErrorWithStatus } from "ente-base/http";
import type { EnteFile } from "ente-media/file";
import { computeNormalCollectionFilesFromSaved } from "../file";
import { savedCGroups } from "../user-entity";
import {
    BodyIndex,
    matchBodies,
    type BodyDetection,
    type LocalBodyIndex,
} from "./body";
import { saveBodyIndex, savedBodyIndexes, savedFaceClusters } from "./db";
import { fetchMLData, putMLData } from "./ml-data";
import type { CGroupPerson, PreviewableCluster } from "./people";

let matchCacheKey: string | undefined;
let matchCache: ReturnType<typeof matchBodies> = [];

export const currentBodyMatches = async (files: EnteFile[]) => {
    const facePersons = new Map<string, string>();
    for (const group of await savedCGroups()) {
        const rejected = new Set(group.data.rejectedFaceIDs);
        for (const cluster of group.data.assigned) {
            for (const faceID of cluster.faces)
                if (!rejected.has(faceID)) facePersons.set(faceID, group.id);
        }
    }
    // Unnamed face clusters still compete; otherwise the margin would ignore
    // people the user has not named yet. These IDs are never persisted.
    for (const cluster of await savedFaceClusters()) {
        for (const faceID of cluster.faces) {
            if (!facePersons.has(faceID))
                facePersons.set(faceID, `cluster:${cluster.id}`);
        }
    }
    const indexes = (await savedBodyIndexes()).filter(
        (i) => BodyIndex.safeParse(i).success,
    );
    const key = JSON.stringify([
        indexes,
        files
            .map((f) => [
                f.id,
                f.metadata.creationTime,
                f.pubMagicMetadata?.data.editedTime,
                f.pubMagicMetadata?.data.dateTime,
            ])
            .sort((a, b) => Number(a[0]) - Number(b[0])),
        [...facePersons].sort((a, b) => a[0].localeCompare(b[0])),
    ]);
    if (key != matchCacheKey) {
        matchCache = matchBodies(indexes, files, facePersons);
        matchCacheKey = key;
    }
    return matchCache;
};

export const bodySuggestionsForPerson = async (
    person: CGroupPerson,
): Promise<PreviewableCluster[]> => {
    const files = await computeNormalCollectionFilesFromSaved();
    const fileByID = new Map(files.map((f) => [f.id, f]));
    const manual = new Set(person.cgroup.data.manuallyAssigned);
    return (await currentBodyMatches(files))
        .filter((m) => m.personID == person.id && !manual.has(m.fileID))
        .flatMap((m) => {
            const file = fileByID.get(m.fileID);
            return file
                ? [
                      {
                          id: m.detection.bodyID,
                          faces: [m.detection.bodyID],
                          previewFaces: [
                              {
                                  faceID: m.detection.bodyID,
                                  file,
                                  body: m.detection,
                              },
                          ],
                      },
                  ]
                : [];
        });
};

export const bodyChoicesForPerson = async (person: CGroupPerson) => {
    const fileByID = new Map(
        (await computeNormalCollectionFilesFromSaved()).map((f) => [f.id, f]),
    );
    const manual = new Set(person.cgroup.data.manuallyAssigned);
    return (await savedBodyIndexes()).flatMap((index) => {
        const file = fileByID.get(index.fileID);
        if (!file) return [];
        return index.detections
            .filter((d) => d.decisions[person.id])
            .map((body) => ({
                id: body.bodyID,
                faces: [body.bodyID],
                previewFaces: [{ faceID: body.bodyID, file, body }],
                assigned:
                    body.decisions[person.id]!.status == "accepted" &&
                    manual.has(index.fileID),
            }));
    });
};

export const bodyWithID = async (
    bodyID: string,
): Promise<{
    fileID: number;
    index: LocalBodyIndex;
    detection: BodyDetection;
}> => {
    const fileID = Number(bodyID.substring(5).split("_")[0]);
    const index = (await savedBodyIndexes()).find((i) => i.fileID == fileID);
    const detection = index?.detections.find((d) => d.bodyID == bodyID);
    if (!index || !detection) throw new Error(`Missing body ${bodyID}`);
    return { fileID, index, detection };
};

export const updateBodyDecision = async (
    file: EnteFile,
    bodyID: string,
    personID: string,
    decision: BodyDetection["decisions"][string] | undefined,
) => {
    for (let attempt = 0; attempt < 3; attempt++) {
        const remote = (await fetchMLData(new Map([[file.id, file]]))).get(
            file.id,
        );
        const parsed = BodyIndex.safeParse(remote?.raw.body);
        if (!remote || !parsed.success)
            throw new Error("Body index is unavailable");
        const index = parsed.data;
        const detection = index.detections.find((d) => d.bodyID == bodyID);
        if (!detection) throw new Error("Body detection is unavailable");
        if (decision) detection.decisions[personID] = decision;
        else
            detection.decisions = Object.fromEntries(
                Object.entries(detection.decisions).filter(
                    ([id]) => id != personID,
                ),
            );
        try {
            await putMLData(
                file,
                { ...remote.raw, body: index },
                remote.updatedAt ?? 0,
            );
            await saveBodyIndex({ ...index, fileID: file.id });
            return;
        } catch (e) {
            if (!isHTTPErrorWithStatus(e, 409) || attempt == 2) throw e;
        }
    }
};
