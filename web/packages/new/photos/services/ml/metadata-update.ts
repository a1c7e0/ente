import { isHTTPErrorWithStatus } from "ente-base/http";

// Retry the mutation, rather than the stale whole-object upload.
export const mergeMetadata = async <T>(
    read: () => Promise<{ data: T; updatedAt?: number }>,
    write: (data: T, updatedAt: number) => Promise<void>,
    update: (data: T) => unknown,
): Promise<T> => {
    for (let attempt = 0; attempt < 3; attempt++) {
        const { data, updatedAt } = await read();
        if ((await update(data)) === false) return data;
        try {
            await write(data, updatedAt ?? 0);
            return data;
        } catch (e) {
            if (!isHTTPErrorWithStatus(e, 409) || attempt == 2) throw e;
        }
    }
    throw new Error("Metadata update failed");
};
