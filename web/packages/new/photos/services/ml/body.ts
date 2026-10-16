import type { EnteFile } from "ente-media/file";
import { fileCreationPhotoSortTime } from "ente-media/file-metadata";
import { z } from "zod";
import type { Face } from "./face";

export const bodyIndexingVersion = 1;
export const bodyModel = "osnet-ain-x1.0-msmt17-v1";
export const bodyEmbeddingPrecision = "decimal4-v1";

const compactEmbedding = (embedding: number[]) =>
    embedding.map((value) =>
        value === 0 || !Number.isFinite(value)
            ? value
            : Number(value.toPrecision(4)),
    );

export const isUnsupportedBodyIndex = (value: unknown) => {
    if (!value || typeof value != "object") return false;
    const raw = value as { version?: number; model?: string };
    return (
        typeof raw.version == "number" &&
        (raw.version > bodyIndexingVersion ||
            (raw.version >= bodyIndexingVersion &&
                typeof raw.model == "string" &&
                raw.model != bodyModel))
    );
};

export const BodyDetection = z.looseObject({
    bodyID: z.string().startsWith("body:"),
    box: z.object({
        x: z.number().min(0).max(1),
        y: z.number().min(0).max(1),
        width: z.number().positive().max(1),
        height: z.number().positive().max(1),
    }),
    score: z.number().min(0).max(1),
    embedding: z
        .array(z.number())
        .length(512)
        .refine((v) => v.some((x) => x != 0))
        .transform(compactEmbedding),
    linkedFaceID: z.string().nullish(),
    groupID: z.string().startsWith("body-group:").optional(),
    rejectedAnchorFaceIDs: z.array(z.string()).optional(),
    decisions: z
        .record(
            z.string(),
            z.looseObject({
                status: z.enum(["accepted", "rejected"]),
                addedManual: z.boolean().optional(),
            }),
        )
        .default({}),
});
export type BodyDetection = z.infer<typeof BodyDetection>;

export const BodyIndex = z.looseObject({
    version: z.literal(bodyIndexingVersion),
    model: z.literal(bodyModel),
    client: z.string(),
    embeddingPrecision: z.string().optional(),
    width: z.number().int().positive(),
    height: z.number().int().positive(),
    detections: z.array(BodyDetection),
});
export type BodyIndex = z.infer<typeof BodyIndex>;
export type LocalBodyIndex = BodyIndex & { fileID: number };

export const compactBodyIndex = (index: BodyIndex): BodyIndex => ({
    ...index,
    embeddingPrecision: bodyEmbeddingPrecision,
    detections: index.detections.map((detection) => ({
        ...detection,
        embedding: compactEmbedding(detection.embedding),
    })),
});

export interface BodyMatch {
    fileID: number;
    detection: BodyDetection;
    personID: string;
    similarity: number;
    margin: number;
}

export const isBodyReference = (id: string) =>
    id.startsWith("body:") || id.startsWith("body-group:");

export interface BodyGroup {
    id: string;
    personID: string;
    matches: BodyMatch[];
}

// Complete-link grouping prevents a chain of similar clothes from joining
// dissimilar endpoints. Explicit partitions from human splits never rejoin.
export const groupBodyMatches = (
    matches: BodyMatch[],
    files: EnteFile[],
    threshold = 0.8,
): BodyGroup[] => {
    const times = new Map(
        files.map((f) => [f.id, fileCreationPhotoSortTime(f)]),
    );
    const groups: BodyGroup[] = [];
    const ordered = [...matches].sort((a, b) =>
        a.detection.bodyID < b.detection.bodyID
            ? -1
            : a.detection.bodyID > b.detection.bodyID
              ? 1
              : 0,
    );
    for (const match of ordered) {
        const partition = match.detection.groupID;
        const group = groups.find(
            (g) =>
                g.personID == match.personID &&
                (partition
                    ? g.id == partition
                    : !g.matches[0]!.detection.groupID) &&
                g.matches.every(
                    (m) =>
                        m.fileID != match.fileID &&
                        (partition ||
                            ((times.get(m.fileID) ?? 0) > 0 &&
                                (times.get(match.fileID) ?? 0) > 0 &&
                                Math.abs(
                                    (times.get(m.fileID) ?? 0) -
                                        (times.get(match.fileID) ?? 0),
                                ) <=
                                    3 * 60 * 60 * 1000 &&
                                bodyCosine(
                                    m.detection.embedding,
                                    match.detection.embedding,
                                ) >= threshold)),
                ),
        );
        if (group) group.matches.push(match);
        else
            groups.push({
                id:
                    partition ??
                    `body-group:${match.detection.bodyID.substring(5)}`,
                personID: match.personID,
                matches: [match],
            });
    }
    return groups;
};
export const isAutomaticBodyMatch = (m: BodyMatch) =>
    m.similarity >= 0.74 && m.margin >= 0.05;

export const linkBodyFaces = (
    detections: {
        bodyId: string;
        boxXyxy: number[];
        score: number;
        embedding: number[];
    }[],
    faces: Face[],
): BodyDetection[] => {
    const used = new Set<string>();
    return detections.flatMap((d) => {
        const [x, y, x2, y2] = d.boxXyxy as [number, number, number, number];
        const contained = faces
            .filter((f) => {
                const b = f.detection.box;
                const cx = b.x + b.width / 2,
                    cy = b.y + b.height / 2;
                return (
                    f.score > 0 && cx >= x && cx <= x2 && cy >= y && cy <= y2
                );
            })
            .sort((a, b) => b.score - a.score);
        if (contained.length > 1) return [];
        const linkedFaceID =
            contained.length == 1 && !used.has(contained[0]!.faceID)
                ? contained[0]!.faceID
                : null;
        if (linkedFaceID) used.add(linkedFaceID);
        return [
            {
                bodyID: d.bodyId,
                box: { x, y, width: x2 - x, height: y2 - y },
                score: d.score,
                embedding: compactEmbedding(d.embedding),
                linkedFaceID,
                decisions: {},
            },
        ];
    });
};

export const matchBodies = (
    indexes: LocalBodyIndex[],
    files: EnteFile[],
    facePersons: Map<string, string>,
): BodyMatch[] => {
    const fileByID = new Map(files.map((f) => [f.id, f]));
    const occupancy = new Map<number, Set<string>>();
    for (const [faceID, personID] of facePersons) {
        const fileID = Number(faceID.split("_")[0]);
        const set = occupancy.get(fileID) ?? new Set<string>();
        set.add(personID);
        occupancy.set(fileID, set);
    }
    const time = (id: number) => {
        const f = fileByID.get(id);
        return f && f.metadata.creationTime > 0
            ? fileCreationPhotoSortTime(f)
            : undefined;
    };
    const anchors = indexes.flatMap((index) =>
        index.detections.flatMap((body) => {
            const personID = body.linkedFaceID
                ? facePersons.get(body.linkedFaceID)
                : undefined;
            return personID && fileByID.has(index.fileID)
                ? [{ fileID: index.fileID, body, personID }]
                : [];
        }),
    );
    const result: BodyMatch[] = [];
    for (const index of indexes) {
        const t = time(index.fileID);
        if (!t || t <= 0) continue;
        for (const body of index.detections) {
            if (
                Object.values(body.decisions).some(
                    (d) => d.status == "accepted",
                )
            )
                continue;
            if (body.linkedFaceID && facePersons.has(body.linkedFaceID))
                continue;
            const scores = new Map<string, number>();
            const rejectedPersons = new Set(
                (body.rejectedAnchorFaceIDs ?? [])
                    .map((id) => facePersons.get(id))
                    .filter((id) => id !== undefined),
            );
            for (const anchor of anchors) {
                const at = time(anchor.fileID);
                if (
                    !at ||
                    at <= 0 ||
                    Math.abs(t - at) > 3 * 60 * 60 * 1000 ||
                    occupancy.get(index.fileID)?.has(anchor.personID)
                )
                    continue;
                const s = bodyCosine(body.embedding, anchor.body.embedding);
                if (s > (scores.get(anchor.personID) ?? -1))
                    scores.set(anchor.personID, s);
            }
            const ranked = [...scores].sort((a, b) => b[1] - a[1]);
            const best = ranked[0];
            if (
                !best ||
                best[1] < 0.63 ||
                body.decisions[best[0]] ||
                rejectedPersons.has(best[0])
            )
                continue;
            result.push({
                fileID: index.fileID,
                detection: body,
                personID: best[0],
                similarity: best[1],
                margin: best[1] - (ranked[1]?.[1] ?? -1),
            });
        }
    }
    const reserved = new Map<number, Set<string>>();
    return result
        .sort((a, b) => b.similarity - a.similarity)
        .filter((m) => {
            const set = reserved.get(m.fileID) ?? new Set<string>();
            if (set.has(m.personID)) return false;
            set.add(m.personID);
            reserved.set(m.fileID, set);
            return true;
        });
};

const bodyCosine = (a: number[], b: number[]) => {
    if (!a.length || a.length != b.length) return -1;
    let dot = 0,
        aa = 0,
        bb = 0;
    for (let i = 0; i < a.length; i++) {
        dot += a[i]! * b[i]!;
        aa += a[i]! ** 2;
        bb += b[i]! ** 2;
    }
    return aa > 0 && bb > 0 ? dot / Math.sqrt(aa * bb) : -1;
};
