import type { EnteFile } from "ente-media/file";
import { computeNormalCollectionFilesFromSaved } from "../file";
import { savedCGroups } from "../user-entity";
import {
    BodyIndex,
    groupBodyMatches,
    matchBodies,
    type BodyDetection,
    type LocalBodyIndex,
} from "./body";
import { saveBodyIndex, savedBodyIndexes, savedFaceClusters } from "./db";
import { updateMLData } from "./ml-data";
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

const currentBodyGroups = async (files: EnteFile[]) =>
    groupBodyMatches(await currentBodyMatches(files), files);

export const bodySuggestionsForPerson = async (
    person: CGroupPerson,
): Promise<PreviewableCluster[]> => {
    const files = await computeNormalCollectionFilesFromSaved();
    const fileByID = new Map(files.map((f) => [f.id, f]));
    const manual = new Set(person.cgroup.data.manuallyAssigned);
    return (await currentBodyGroups(files))
        .filter((g) => g.personID == person.id)
        .flatMap((g) => {
            const members = g.matches.filter(
                (m) => !manual.has(m.fileID) && fileByID.has(m.fileID),
            );
            return members.length
                ? [
                      {
                          id: g.id,
                          faces: members.map((m) => m.detection.bodyID),
                          previewFaces: members
                              .slice(0, 5)
                              .map((m) => ({
                                  faceID: m.detection.bodyID,
                                  file: fileByID.get(m.fileID)!,
                                  body: m.detection,
                              })),
                      },
                  ]
                : [];
        });
};

export const bodyChoicesForPerson = async (person: CGroupPerson) => {
    const files = await computeNormalCollectionFilesFromSaved();
    const fileByID = new Map(files.map((f) => [f.id, f]));
    const manual = new Set(person.cgroup.data.manuallyAssigned);
    const grouped = new Map<
        string,
        PreviewableCluster & { assigned: boolean }
    >();
    for (const index of await savedBodyIndexes()) {
        const file = fileByID.get(index.fileID);
        if (!file || !BodyIndex.safeParse(index).success) continue;
        for (const body of index.detections) {
            const decision = body.decisions[person.id];
            if (!decision) continue;
            const id = body.groupID ?? `body-group:${body.bodyID.substring(5)}`;
            const assigned =
                decision.status == "accepted" && manual.has(index.fileID);
            const group = grouped.get(id) ?? {
                id,
                faces: [],
                previewFaces: [],
                assigned: true,
            };
            group.faces.push(body.bodyID);
            if (group.previewFaces.length < 5)
                group.previewFaces.push({ faceID: body.bodyID, file, body });
            group.assigned &&= assigned;
            grouped.set(id, group);
        }
    }
    return [...grouped.values()];
};

export const bodyGroupWithID = async (reference: string) => {
    if (reference.startsWith("body:")) return [await bodyWithID(reference)];
    const saved = (await savedBodyIndexes())
        .filter((i) => BodyIndex.safeParse(i).success)
        .flatMap((index) =>
            index.detections
                .filter((d) => d.groupID == reference)
                .map((detection) => ({
                    fileID: index.fileID,
                    index,
                    detection,
                })),
        );
    if (saved.length) return saved;
    const group = (
        await currentBodyGroups(await computeNormalCollectionFilesFromSaved())
    ).find((g) => g.id == reference);
    if (!group) throw new Error(`Missing body group ${reference}`);
    return Promise.all(
        group.matches.map((m) => bodyWithID(m.detection.bodyID)),
    );
};

export const splitBodyGroup = async (
    reference: string,
    selected: Set<string>,
) => {
    const members = await bodyGroupWithID(reference);
    if (
        !selected.size ||
        members.every((m) => selected.has(m.detection.bodyID))
    )
        throw new Error("Select a proper subset of the body group");
    const newID = `body-group:${crypto.randomUUID()}`;
    const files = new Map(
        (await computeNormalCollectionFilesFromSaved()).map((f) => [f.id, f]),
    );
    for (const member of members) {
        const file = files.get(member.fileID);
        if (!file) throw new Error("Missing body photo");
        const raw = await updateMLData(file, (latest) => {
            const index = BodyIndex.parse(latest.body);
            const body = index.detections.find(
                (d) => d.bodyID == member.detection.bodyID,
            );
            if (!body) throw new Error("Missing body detection");
            body.groupID = selected.has(body.bodyID) ? newID : reference;
            latest.body = index;
        });
        await saveBodyIndex({ ...BodyIndex.parse(raw.body), fileID: file.id });
    }
    return newID;
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
    groupID?: string,
) => {
    const raw = await updateMLData(file, (latest) => {
        const parsed = BodyIndex.safeParse(latest.body);
        if (!parsed.success) throw new Error("Body index is unavailable");
        const index = parsed.data;
        const detection = index.detections.find((d) => d.bodyID == bodyID);
        if (!detection) throw new Error("Body detection is unavailable");
        if (groupID) {
            const id = groupID.startsWith("body-group:")
                ? groupID
                : `body-group:${groupID.substring(5)}`;
            if (detection.groupID && detection.groupID != id)
                throw new Error("Body grouping changed; reload the review");
            detection.groupID = id;
        }
        if (decision) detection.decisions[personID] = decision;
        else
            detection.decisions = Object.fromEntries(
                Object.entries(detection.decisions).filter(
                    ([id]) => id != personID,
                ),
            );
        latest.body = index;
    });
    await saveBodyIndex({ ...BodyIndex.parse(raw.body), fileID: file.id });
};
