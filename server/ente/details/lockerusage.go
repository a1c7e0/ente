package details

// LockerUsageResponse describes Locker file counts and shared Photos/Locker
// storage usage. File count limits are retained for legacy clients only.
type LockerUsageResponse struct {
	QuotaMode          string `json:"quotaMode"`
	IsPaid             bool   `json:"isPaid"`
	IsFamily           bool   `json:"isFamily"`
	UsedFileCount      int64  `json:"usedFileCount"`
	FileLimit          int64  `json:"fileLimit"`
	RemainingFileCount int64  `json:"remainingFileCount"`
	UsedStorage        int64  `json:"usedStorage"`
	StorageLimit       int64  `json:"storageLimit"`
	RemainingStorage   int64  `json:"remainingStorage"`
	UserFileCount      int64  `json:"userFileCount"`
	UserStorage        int64  `json:"userStorage"`
}
