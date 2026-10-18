package user

import (
	"database/sql"
	"fmt"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/ente/cache"
	bonus "github.com/ente/museum/ente/storagebonus"
	"github.com/ente/museum/internal/testutil"
	museumcontroller "github.com/ente/museum/pkg/controller"
	"github.com/ente/museum/pkg/controller/family"
	"github.com/ente/museum/pkg/controller/usercache"
	"github.com/ente/museum/pkg/repo"
	storagebonusrepo "github.com/ente/museum/pkg/repo/storagebonus"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

func TestGetLockerUsageExcludesInvitedFamilyMembersFromFamilyTotals(t *testing.T) {
	controller, db, ctx := setupLockerUsageControllerTest(t)

	adminID := int64(101)
	acceptedMemberID := int64(102)
	invitedMemberID := int64(103)

	insertLockerUsageTestUser(t, db, adminID, &adminID)
	insertLockerUsageTestUser(t, db, acceptedMemberID, &adminID)
	insertLockerUsageTestUser(t, db, invitedMemberID, &adminID)

	insertLockerUsageTestFamilyMember(t, db, adminID, adminID, ente.SELF)
	insertLockerUsageTestFamilyMember(t, db, adminID, acceptedMemberID, ente.ACCEPTED)
	insertLockerUsageTestFamilyMember(t, db, adminID, invitedMemberID, ente.INVITED)
	testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
		UserID: adminID, Storage: 1_000_000, ExpiryTime: time.Now().Add(time.Hour).UnixMicro(),
	})

	insertLockerUsageTestLockerFile(t, db, adminID, 101)
	insertLockerUsageTestLockerFile(t, db, acceptedMemberID, 201)
	insertLockerUsageTestLockerFile(t, db, acceptedMemberID, 202)
	insertLockerUsageTestLockerFile(t, db, invitedMemberID, 301)
	insertLockerUsageTestLockerFile(t, db, invitedMemberID, 302)
	insertLockerUsageTestLockerFile(t, db, invitedMemberID, 303)
	testutil.InsertUsage(t, db, adminID, 5_101)
	testutil.InsertUsage(t, db, acceptedMemberID, 10_403)
	testutil.InsertUsage(t, db, invitedMemberID, 6_030)

	resp, err := controller.GetLockerUsage(ctx, adminID)
	if err != nil {
		t.Fatalf("GetLockerUsage() error = %v", err)
	}

	if !resp.IsFamily {
		t.Fatal("expected family locker usage response")
	}
	if resp.QuotaMode != "sharedStorage" {
		t.Fatalf("unexpected quota mode: got %q want sharedStorage", resp.QuotaMode)
	}
	if resp.UsedFileCount != 3 {
		t.Fatalf("unexpected used file count: got %d want %d", resp.UsedFileCount, 3)
	}
	if resp.UsedStorage != 15_504 {
		t.Fatalf("unexpected combined used storage: got %d want %d", resp.UsedStorage, 15_504)
	}
	if resp.StorageLimit != 1_000_000 {
		t.Fatalf("unexpected shared storage limit: got %d want %d", resp.StorageLimit, 1_000_000)
	}
	if resp.RemainingStorage != 984_496 {
		t.Fatalf("unexpected shared remaining storage: got %d want %d", resp.RemainingStorage, 984_496)
	}
	if resp.UserFileCount != 1 {
		t.Fatalf("unexpected admin file count: got %d want %d", resp.UserFileCount, 1)
	}
	if resp.UserStorage != 5_101 {
		t.Fatalf("unexpected combined admin storage: got %d want %d", resp.UserStorage, 5_101)
	}
}

func TestGetLockerUsageReturnsRequesterSpecificUsageWithinActiveFamilyScope(t *testing.T) {
	controller, db, ctx := setupLockerUsageControllerTest(t)

	adminID := int64(201)
	acceptedMemberID := int64(202)
	invitedMemberID := int64(203)

	insertLockerUsageTestUser(t, db, adminID, &adminID)
	insertLockerUsageTestUser(t, db, acceptedMemberID, &adminID)
	insertLockerUsageTestUser(t, db, invitedMemberID, &adminID)

	insertLockerUsageTestFamilyMember(t, db, adminID, adminID, ente.SELF)
	insertLockerUsageTestFamilyMember(t, db, adminID, acceptedMemberID, ente.ACCEPTED)
	insertLockerUsageTestFamilyMember(t, db, adminID, invitedMemberID, ente.INVITED)
	testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
		UserID: adminID, Storage: 40_000, ExpiryTime: time.Now().Add(time.Hour).UnixMicro(),
	})
	if _, err := db.Exec(`UPDATE families SET storage_limit = $1 WHERE admin_id = $2 AND member_id = $3`, 25_000, adminID, acceptedMemberID); err != nil {
		t.Fatal(err)
	}

	insertLockerUsageTestLockerFile(t, db, adminID, 111)
	insertLockerUsageTestLockerFile(t, db, acceptedMemberID, 211)
	insertLockerUsageTestLockerFile(t, db, acceptedMemberID, 212)
	insertLockerUsageTestLockerFile(t, db, invitedMemberID, 311)
	testutil.InsertUsage(t, db, adminID, 10_111)
	testutil.InsertUsage(t, db, acceptedMemberID, 20_423)
	testutil.InsertUsage(t, db, invitedMemberID, 10_311)

	resp, err := controller.GetLockerUsage(ctx, acceptedMemberID)
	if err != nil {
		t.Fatalf("GetLockerUsage() error = %v", err)
	}

	if !resp.IsFamily {
		t.Fatal("expected family locker usage response")
	}
	if resp.QuotaMode != "sharedStorage" {
		t.Fatalf("unexpected quota mode: got %q want sharedStorage", resp.QuotaMode)
	}
	if resp.UsedFileCount != 3 {
		t.Fatalf("unexpected used file count: got %d want %d", resp.UsedFileCount, 3)
	}
	if resp.UsedStorage != 30_534 {
		t.Fatalf("unexpected combined used storage: got %d want %d", resp.UsedStorage, 30_534)
	}
	if resp.StorageLimit != 40_000 {
		t.Fatalf("unexpected family storage limit: got %d want %d", resp.StorageLimit, 40_000)
	}
	if resp.RemainingStorage != 4_577 {
		t.Fatalf("remaining storage should use the smaller member allowance: got %d want %d", resp.RemainingStorage, 4_577)
	}
	if resp.UserFileCount != 2 {
		t.Fatalf("unexpected member file count: got %d want %d", resp.UserFileCount, 2)
	}
	if resp.UserStorage != 20_423 {
		t.Fatalf("unexpected combined member storage: got %d want %d", resp.UserStorage, 20_423)
	}
	if _, err := db.Exec(`UPDATE usage SET storage_consumed = $1 WHERE user_id = $2`, 50_000, adminID); err != nil {
		t.Fatal(err)
	}
	resp, err = controller.GetLockerUsage(ctx, acceptedMemberID)
	if err != nil {
		t.Fatalf("GetLockerUsage() after family overage error = %v", err)
	}
	if resp.RemainingStorage != 0 {
		t.Fatalf("remaining storage should clamp to zero above shared limit: got %d want 0", resp.RemainingStorage)
	}
}

func TestGetLockerUsageIncludesActiveBonusInSharedLimitAndClampsRemaining(t *testing.T) {
	controller, db, ctx := setupLockerUsageControllerTest(t)
	userID := int64(301)
	insertLockerUsageTestUser(t, db, userID, nil)
	testutil.InsertSubscription(t, db, testutil.SubscriptionFixture{
		UserID: userID, Storage: 1_000, ExpiryTime: time.Now().Add(time.Hour).UnixMicro(),
	})
	testutil.InsertUsage(t, db, userID, 1_500)
	_, err := db.Exec(`INSERT INTO storage_bonus(bonus_id, type, user_id, storage, valid_till)
		VALUES($1, $2, $3, $4, 0)`, uuid.NewString(), bonus.SignUp, userID, 1_000)
	if err != nil {
		t.Fatal(err)
	}

	resp, err := controller.GetLockerUsage(ctx, userID)
	if err != nil {
		t.Fatalf("GetLockerUsage() error = %v", err)
	}
	if resp.StorageLimit != 2_000 || resp.RemainingStorage != 500 {
		t.Fatalf("bonus quota = (limit %d, remaining %d); want (2000, 500)", resp.StorageLimit, resp.RemainingStorage)
	}
	if _, err := db.Exec(`UPDATE usage SET storage_consumed = $1 WHERE user_id = $2`, 2_001, userID); err != nil {
		t.Fatal(err)
	}
	resp, err = controller.GetLockerUsage(ctx, userID)
	if err != nil {
		t.Fatalf("GetLockerUsage() above quota error = %v", err)
	}
	if resp.RemainingStorage != 0 {
		t.Fatalf("remaining storage should clamp to zero above quota: got %d want 0", resp.RemainingStorage)
	}
}

func setupLockerUsageControllerTest(t *testing.T) (*UserController, *sql.DB, *gin.Context) {
	t.Helper()

	testutil.WithServerRoot(t)

	db := testutil.RequireTestDB(t)
	testutil.ResetTables(t, db)
	t.Cleanup(func() {
		testutil.ResetTables(t, db)
	})

	gin.SetMode(gin.TestMode)
	recorder := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(recorder)

	userRepo := &repo.UserRepository{
		DB:                  db,
		SecretEncryptionKey: testutil.SecretEncryptionKey(),
		HashingKey:          testutil.HashingKey(),
	}
	usageRepo := &repo.UsageRepository{
		DB:       db,
		UserRepo: userRepo,
	}
	billingRepo := &repo.BillingRepository{DB: db}
	storageBonusRepo := &storagebonusrepo.Repository{DB: db}
	userCache := cache.NewUserCache()

	return &UserController{
		UserRepo:  userRepo,
		UsageRepo: usageRepo,
		BillingController: &museumcontroller.BillingController{
			BillingRepo:      billingRepo,
			UserRepo:         userRepo,
			StorageBonusRepo: storageBonusRepo,
		},
		FamilyController: &family.Controller{
			FamilyRepo:    &repo.FamilyRepository{DB: db},
			UserRepo:      userRepo,
			UserCacheCtrl: &usercache.Controller{StoreBonusRepo: storageBonusRepo, UserCache: userCache},
		},
		UserCacheController: &usercache.Controller{StoreBonusRepo: storageBonusRepo, UserCache: userCache},
	}, db, ctx
}

func insertLockerUsageTestUser(t *testing.T, db *sql.DB, userID int64, familyAdminID *int64) {
	t.Helper()

	testutil.InsertUser(t, db, testutil.UserFixture{
		UserID:        userID,
		Email:         fmt.Sprintf("locker-usage-user-%d@ente.com", userID),
		CreationTime:  1,
		FamilyAdminID: familyAdminID,
	})
}

func insertLockerUsageTestFamilyMember(t *testing.T, db *sql.DB, adminID, memberID int64, status ente.MemberStatus) {
	t.Helper()

	_, err := db.Exec(
		`INSERT INTO families(id, admin_id, member_id, status)
		 VALUES($1, $2, $3, $4)`,
		uuid.New(),
		adminID,
		memberID,
		status,
	)
	if err != nil {
		t.Fatalf("failed to insert family member %d for admin %d: %v", memberID, adminID, err)
	}
}

func insertLockerUsageTestLockerFile(t *testing.T, db *sql.DB, ownerID, size int64) {
	t.Helper()

	var collectionID int64
	err := db.QueryRow(
		`INSERT INTO collections(owner_id, encrypted_key, key_decryption_nonce, name, type, attributes, updation_time, is_deleted, app)
		 VALUES($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9)
		 RETURNING collection_id`,
		ownerID,
		"encrypted-key",
		"key-nonce",
		"Locker collection",
		"album",
		"{}",
		size,
		false,
		string(ente.Locker),
	).Scan(&collectionID)
	if err != nil {
		t.Fatalf("failed to insert collection for owner %d: %v", ownerID, err)
	}

	var fileID int64
	err = db.QueryRow(
		`INSERT INTO files(owner_id, file_decryption_header, thumbnail_decryption_header, metadata_decryption_header, encrypted_metadata, updation_time, info)
		 VALUES($1, $2, $3, $4, $5, $6, $7::jsonb)
		 RETURNING file_id`,
		ownerID,
		"file-header",
		"thumbnail-header",
		"metadata-header",
		"encrypted-metadata",
		size,
		"{}",
	).Scan(&fileID)
	if err != nil {
		t.Fatalf("failed to insert file for owner %d: %v", ownerID, err)
	}

	_, err = db.Exec(
		`INSERT INTO collection_files(collection_id, file_id, encrypted_key, key_decryption_nonce, is_deleted, updation_time, c_owner_id, f_owner_id)
		 VALUES($1, $2, $3, $4, $5, $6, $7, $8)`,
		collectionID,
		fileID,
		"collection-file-key",
		"collection-file-nonce",
		false,
		size,
		ownerID,
		ownerID,
	)
	if err != nil {
		t.Fatalf("failed to link file %d to collection %d: %v", fileID, collectionID, err)
	}

	_, err = db.Exec(
		`INSERT INTO object_keys(file_id, o_type, object_key, size, datacenters)
		 VALUES($1, 'file', $2, $3, ARRAY['b2-eu-cen']::s3region[])`,
		fileID,
		uuid.NewString(),
		size,
	)
	if err != nil {
		t.Fatalf("failed to insert object key for file %d: %v", fileID, err)
	}
}
