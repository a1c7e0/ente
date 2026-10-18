package controller

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/ente/cache"
	bonus "github.com/ente/museum/ente/storagebonus"
	"github.com/ente/museum/internal/testutil"
	"github.com/ente/museum/pkg/controller/usercache"
	"github.com/ente/museum/pkg/repo"
	storagebonusrepo "github.com/ente/museum/pkg/repo/storagebonus"
	"github.com/google/uuid"
)

func TestLockerUploadsUseSharedStorageAndIgnoreLockerFileCount(t *testing.T) {
	controller, db, userID := setupSharedStorageUsageTest(t)
	insertSharedStorageUsageUser(t, db, userID, nil)
	testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
		UserID: userID, Storage: 10_000, ExpiryTime: time.Now().Add(time.Hour).UnixMicro(),
	})
	testutil.InsertUsage(t, db, userID, 1_001)
	if _, err := db.Exec(`UPDATE usage SET photos_file_count = 0, locker_file_count = 1001 WHERE user_id = $1`, userID); err != nil {
		t.Fatal(err)
	}

	if err := controller.CanUploadFile(context.Background(), userID, nil, ente.Locker); err != nil {
		t.Fatalf("Locker upload under shared byte limit was rejected with 1001 files: %v", err)
	}
}

func TestLockerUploadIsDeniedWhenSharedUsageExceedsPlanAndGrace(t *testing.T) {
	controller, db, userID := setupSharedStorageUsageTest(t)
	insertSharedStorageUsageUser(t, db, userID, nil)
	testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
		UserID: userID, Storage: 1_000, ExpiryTime: time.Now().Add(time.Hour).UnixMicro(),
	})
	testutil.InsertUsage(t, db, userID, 1_000+StorageOverflowAboveSubscriptionLimit+1)
	if _, err := db.Exec(`UPDATE usage SET photos_file_count = 1, locker_file_count = 0 WHERE user_id = $1`, userID); err != nil {
		t.Fatal(err)
	}

	err := controller.CanUploadFile(context.Background(), userID, nil, ente.Locker)
	if !errors.Is(err, ente.ErrStorageLimitExceeded) {
		t.Fatalf("Locker upload error = %v; want shared storage limit exceeded", err)
	}
}

func TestPhotosUploadCountsLockerBytesAgainstSharedLimit(t *testing.T) {
	controller, db, userID := setupSharedStorageUsageTest(t)
	insertSharedStorageUsageUser(t, db, userID, nil)
	testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
		UserID: userID, Storage: 1_000, ExpiryTime: time.Now().Add(time.Hour).UnixMicro(),
	})
	testutil.InsertUsage(t, db, userID, 1_000+StorageOverflowAboveSubscriptionLimit+1)
	if err := insertSharedStorageLockerFile(t, db, userID, 1_000+StorageOverflowAboveSubscriptionLimit+1); err != nil {
		t.Fatal(err)
	}

	err := controller.CanUploadFile(context.Background(), userID, nil, ente.Photos)
	if !errors.Is(err, ente.ErrStorageLimitExceeded) {
		t.Fatalf("Photos upload error = %v; want shared storage limit exceeded", err)
	}
}

func TestSharedStorageKeepsUploadGraceAndUsesStorageBonus(t *testing.T) {
	t.Run("50 MiB upload grace remains available", func(t *testing.T) {
		controller, db, userID := setupSharedStorageUsageTest(t)
		insertSharedStorageUsageUser(t, db, userID, nil)
		testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
			UserID: userID, Storage: 1_000, ExpiryTime: time.Now().Add(time.Hour).UnixMicro(),
		})
		testutil.InsertUsage(t, db, userID, 1_000)
		graceSize := StorageOverflowAboveSubscriptionLimit
		if err := controller.CanUploadFile(context.Background(), userID, &graceSize, ente.Locker); err != nil {
			t.Fatalf("upload exactly within overflow grace was rejected: %v", err)
		}
	})

	t.Run("active referral bonus is usable", func(t *testing.T) {
		controller, db, userID := setupSharedStorageUsageTest(t)
		insertSharedStorageUsageUser(t, db, userID, nil)
		testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
			UserID: userID, Storage: 1_000, ExpiryTime: time.Now().Add(time.Hour).UnixMicro(),
		})
		testutil.InsertUsage(t, db, userID, 1_500)
		_, err := db.Exec(`INSERT INTO storage_bonus(bonus_id, type, user_id, storage, valid_till)
			VALUES($1, $2, $3, $4, 0)`, uuid.NewString(), bonus.SignUp, userID, 1_000)
		if err != nil {
			t.Fatal(err)
		}

		if err := controller.CanUploadFile(context.Background(), userID, nil, ente.Locker); err != nil {
			t.Fatalf("upload within plan plus active bonus was rejected: %v", err)
		}
	})
}

func TestFamilyMemberStorageLimitAppliesToLockerUploads(t *testing.T) {
	controller, db, adminID := setupSharedStorageUsageTest(t)
	memberID := adminID + 1
	insertSharedStorageUsageUser(t, db, adminID, &adminID)
	insertSharedStorageUsageUser(t, db, memberID, &adminID)
	testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
		UserID: adminID, Storage: 1 << 30, ExpiryTime: time.Now().Add(time.Hour).UnixMicro(),
	})
	memberLimit := int64(1_000)
	_, err := db.Exec(`INSERT INTO families(id, admin_id, member_id, status, storage_limit)
		VALUES($1, $2, $3, $4, $5)`, uuid.New(), adminID, adminID, ente.SELF, nil)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`INSERT INTO families(id, admin_id, member_id, status, storage_limit)
		VALUES($1, $2, $3, $4, $5)`, uuid.New(), adminID, memberID, ente.ACCEPTED, memberLimit)
	if err != nil {
		t.Fatal(err)
	}
	testutil.InsertUsage(t, db, adminID, 0)
	testutil.InsertUsage(t, db, memberID, memberLimit+StorageOverflowAboveSubscriptionLimit+1)

	err = controller.CanUploadFile(context.Background(), memberID, nil, ente.Locker)
	if !errors.Is(err, ente.ErrStorageLimitExceeded) {
		t.Fatalf("Locker upload over member limit error = %v; want member storage limit exceeded", err)
	}
}

func setupSharedStorageUsageTest(t *testing.T) (*UsageController, *sql.DB, int64) {
	t.Helper()
	testutil.WithServerRoot(t)
	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() { testutil.ResetTables(t, db) })

	userRepo := &repo.UserRepository{DB: db, SecretEncryptionKey: testutil.SecretEncryptionKey(), HashingKey: testutil.HashingKey()}
	usageRepo := &repo.UsageRepository{DB: db, UserRepo: userRepo}
	bonusRepo := &storagebonusrepo.Repository{DB: db}
	userCacheController := &usercache.Controller{StoreBonusRepo: bonusRepo, UserCache: cache.NewUserCache()}
	controller := &UsageController{
		BillingCtrl:       &BillingController{BillingRepo: &repo.BillingRepository{DB: db}, UserRepo: userRepo},
		UserCacheCtrl:     userCacheController,
		UsageRepo:         usageRepo,
		UserRepo:          userRepo,
		FamilyRepo:        &repo.FamilyRepository{DB: db},
		UploadResultCache: make(map[int64]bool),
	}
	return controller, db, int64(501)
}

func insertSharedStorageUsageUser(t *testing.T, db *sql.DB, userID int64, familyAdminID *int64) {
	t.Helper()
	testutil.InsertUser(t, db, testutil.UserFixture{
		UserID: userID, Email: fmt.Sprintf("shared-storage-%d@ente.io", userID), CreationTime: 1, FamilyAdminID: familyAdminID,
	})
}

func insertSharedStorageLockerFile(t *testing.T, db *sql.DB, ownerID, size int64) error {
	t.Helper()
	var collectionID, fileID int64
	err := db.QueryRow(`INSERT INTO collections(owner_id, encrypted_key, key_decryption_nonce, name, type, attributes, updation_time, is_deleted, app)
		VALUES($1, 'key', 'nonce', 'Locker', 'album', '{}'::jsonb, 1, false, 'locker') RETURNING collection_id`, ownerID).Scan(&collectionID)
	if err != nil {
		return err
	}
	err = db.QueryRow(`INSERT INTO files(owner_id, file_decryption_header, thumbnail_decryption_header, metadata_decryption_header, encrypted_metadata, updation_time, info)
		VALUES($1, 'file', 'thumb', 'metadata', 'encrypted', 1, '{}'::jsonb) RETURNING file_id`, ownerID).Scan(&fileID)
	if err != nil {
		return err
	}
	_, err = db.Exec(`INSERT INTO collection_files(collection_id, file_id, encrypted_key, key_decryption_nonce, is_deleted, updation_time, c_owner_id, f_owner_id)
		VALUES($1, $2, 'key', 'nonce', false, 1, $3, $3)`, collectionID, fileID, ownerID)
	if err != nil {
		return err
	}
	_, err = db.Exec(`INSERT INTO object_keys(file_id, o_type, object_key, size, datacenters)
		VALUES($1, 'file', $2, $3, ARRAY['b2-eu-cen']::s3region[])`, fileID, uuid.NewString(), size)
	return err
}
