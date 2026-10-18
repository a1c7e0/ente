import { describe, expect, it } from "vitest";
import {
    exceedsPaidLockerHardLimit,
    LOCKER_MAX_FILE_SIZE_BYTES,
    lockerUploadAllowance,
    validateLockerUploadBatch,
    type LockerUploadLimitState,
} from "../src/services/locker-limits";

const file = (size: number) => ({ size }) as File;

describe("Locker upload quota modes", () => {
    it("uses the server remaining byte quota and allows an exact fit", () => {
        const details: LockerUploadLimitState = {
            quotaMode: "sharedStorage",
            usage: 9_000,
            storageLimit: 20_000,
            remainingStorage: 1_000,
            fileCount: 50_000,
            lockerFileLimit: 100,
            isPartOfFamily: true,
        };

        expect(lockerUploadAllowance(details).freeStorage).toBe(1_000);
        expect(validateLockerUploadBatch([file(1_000)], details)).toBeNull();
        expect(validateLockerUploadBatch([file(1_001)], details)).toEqual({
            reason: "storageLimit",
        });
        expect(exceedsPaidLockerHardLimit([file(1)], details)).toBe(false);
    });

    it("checks the combined batch size against remaining member storage", () => {
        const details: LockerUploadLimitState = {
            quotaMode: "sharedStorage",
            usage: 100,
            storageLimit: 10_000,
            remainingStorage: 1_000,
            fileCount: 0,
            lockerFileLimit: 0,
            isPartOfFamily: false,
        };

        expect(
            validateLockerUploadBatch([file(600), file(401)], details),
        ).toEqual({ reason: "storageLimit" });
    });

    it("rejects positive bytes at zero remaining storage and accepts an empty batch", () => {
        const details: LockerUploadLimitState = {
            quotaMode: "sharedStorage",
            usage: 1_000,
            storageLimit: 1_000,
            remainingStorage: 0,
            fileCount: 0,
            lockerFileLimit: 0,
            isPartOfFamily: false,
        };

        expect(validateLockerUploadBatch([file(1)], details)).toEqual({
            reason: "storageLimit",
        });
        expect(validateLockerUploadBatch([], details)).toBeNull();
    });

    it("does not impose a file-count or 10 GiB total cap in shared mode", () => {
        const tinyFiles = Array.from({ length: 1_001 }, () => file(1));
        const details: LockerUploadLimitState = {
            quotaMode: "sharedStorage",
            usage: 0,
            storageLimit: 30 * 1024 ** 3,
            remainingStorage: 30 * 1024 ** 3,
            fileCount: 100_000,
            lockerFileLimit: 1,
            isPartOfFamily: false,
        };

        expect(validateLockerUploadBatch(tinyFiles, details)).toBeNull();
        expect(
            validateLockerUploadBatch(
                [file(10 * 1024 ** 3), file(10 * 1024 ** 3)],
                details,
            ),
        ).toBeNull();
    });

    it("retains the per-file 10 GiB technical limit", () => {
        const details: LockerUploadLimitState = {
            quotaMode: "sharedStorage",
            usage: 0,
            storageLimit: 20 * 1024 ** 3,
            remainingStorage: 20 * 1024 ** 3,
            fileCount: 0,
            lockerFileLimit: 0,
            isPartOfFamily: false,
        };

        expect(
            validateLockerUploadBatch(
                [file(LOCKER_MAX_FILE_SIZE_BYTES + 1)],
                details,
            ),
        ).toEqual({ reason: "fileTooLarge", fileName: undefined });
    });

    it("retains file-count and usage-derived storage limits for legacy responses", () => {
        const details: LockerUploadLimitState = {
            usage: 9_000,
            storageLimit: 10_000,
            fileCount: 100,
            lockerFileLimit: 100,
            isPartOfFamily: false,
        };

        expect(validateLockerUploadBatch([file(1)], details)).toEqual({
            reason: "fileCountLimit",
        });
        expect(
            validateLockerUploadBatch([file(1_001)], {
                ...details,
                fileCount: 0,
            }),
        ).toEqual({ reason: "storageLimit" });
    });
});
