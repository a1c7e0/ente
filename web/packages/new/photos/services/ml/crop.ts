import { blobCache } from "ente-base/blob-cache";
import type { EnteFile } from "ente-media/file";
import { metadataHash } from "ente-media/file-metadata";
import { fetchRenderableEnteFileBlob } from "./blob";
import type { Box, FaceIndex } from "./face";
import { clamp } from "./math";

const inFlightBodyCropBlobs = new Map<string, Promise<Blob>>();

/** Return a cached body crop, generating and caching it once per source revision. */
export const bodyCropBlob = async (
    bodyID: string,
    file: EnteFile,
    box: Box,
): Promise<Blob> => {
    // A file ID can receive new content after an update. Keep its crop cache
    // entry tied to the source hash when available, and otherwise to the file
    // revision timestamp. The box is part of the key because one body can be
    // requested with a refined detection box.
    const sourceRevision = metadataHash(file.metadata) ?? file.updationTime;
    const cacheKey = `body-crop:${JSON.stringify([
        bodyID,
        sourceRevision,
        box.x,
        box.y,
        box.width,
        box.height,
    ])}`;
    const cache = await blobCache("face-crops");
    const cached = await cache.get(cacheKey);
    if (cached) return cached;

    let inFlight = inFlightBodyCropBlobs.get(cacheKey);
    if (!inFlight) {
        inFlight = (async () => {
            const bitmap = await createImageBitmap(
                await fetchRenderableEnteFileBlob(file),
            );
            try {
                const crop = await extractFaceCrop(bitmap, box);
                await cache.put(cacheKey, crop);
                return crop;
            } finally {
                bitmap.close();
            }
        })();
        inFlightBodyCropBlobs.set(cacheKey, inFlight);
    }

    try {
        return await inFlight;
    } finally {
        if (inFlightBodyCropBlobs.get(cacheKey) === inFlight)
            inFlightBodyCropBlobs.delete(cacheKey);
    }
};

// Face crops are local-only and must be regenerated on other clients.
export const regenerateFaceCrops = async (
    file: EnteFile,
    faceIndex: FaceIndex,
) => {
    const renderableBlob = await fetchRenderableEnteFileBlob(file);
    const imageBitmap = await createImageBitmap(renderableBlob);

    try {
        await saveFaceCrops(imageBitmap, faceIndex);
    } finally {
        imageBitmap.close();
    }
};

// Native crops are index-aligned with faces; null slots must be skipped.
export const saveFaceCropBlobs = async (
    faceCrops: (Uint8Array<ArrayBuffer> | null)[],
    faceIndex: FaceIndex,
) => {
    const cache = await blobCache("face-crops");

    return Promise.all(
        faceIndex.faces.flatMap(({ faceID }, i) => {
            const crop = faceCrops[i];
            return crop
                ? [cache.put(faceID, new Blob([crop], { type: "image/jpeg" }))]
                : [];
        }),
    );
};

const saveFaceCrops = async (
    imageBitmap: ImageBitmap,
    faceIndex: FaceIndex,
) => {
    const cache = await blobCache("face-crops");

    return Promise.all(
        faceIndex.faces.map(({ faceID, detection }) =>
            extractFaceCrop(imageBitmap, detection.box).then((b) =>
                cache.put(faceID, b),
            ),
        ),
    );
};

export const extractFaceCrop = (imageBitmap: ImageBitmap, faceBox: Box) => {
    const { width: imageWidth, height: imageHeight } = imageBitmap;

    // Detection boxes use normalized 0–1 coordinates.
    const faceX = faceBox.x * imageWidth;
    const faceY = faceBox.y * imageHeight;
    const faceWidth = faceBox.width * imageWidth;
    const faceHeight = faceBox.height * imageHeight;

    // Reduce padding symmetrically when a face is near an image edge.
    const regularPadding = 0.4;
    const minimumPadding = 0.1;
    const xCrop = faceX - faceWidth * regularPadding;
    const xOvershoot = Math.abs(Math.min(0, xCrop)) / faceWidth;
    const widthCrop =
        faceWidth * (1 + 2 * regularPadding) -
        2 * Math.min(xOvershoot, regularPadding - minimumPadding) * faceWidth;

    const yCrop = faceY - faceHeight * regularPadding;
    const yOvershoot = Math.abs(Math.min(0, yCrop)) / faceHeight;
    const heightCrop =
        faceHeight * (1 + 2 * regularPadding) -
        2 * Math.min(yOvershoot, regularPadding - minimumPadding) * faceHeight;

    const x = clamp(xCrop, 0, imageWidth);
    const y = clamp(yCrop, 0, imageHeight);
    const width = clamp(widthCrop, 0, imageWidth - x);
    const height = clamp(heightCrop, 0, imageHeight - y);

    const canvas = new OffscreenCanvas(width, height);
    const ctx = canvas.getContext("2d")!;
    ctx.imageSmoothingQuality = "high";

    ctx.drawImage(imageBitmap, x, y, width, height, 0, 0, width, height);

    return canvas.convertToBlob({ type: "image/jpeg", quality: 0.8 });
};
