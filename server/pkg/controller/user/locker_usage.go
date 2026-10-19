package user

import (
	"errors"

	"github.com/ente/museum/ente"
	"github.com/ente/museum/ente/details"
	"github.com/ente/museum/pkg/controller"
	"github.com/ente/museum/pkg/repo"
	"github.com/ente/stacktrace"
	"github.com/gin-gonic/gin"
)

func (c *UserController) GetLockerUsage(ctx *gin.Context, userID int64) (details.LockerUsageResponse, error) {
	user, err := c.GetUser(userID)
	if err != nil {
		return details.LockerUsageResponse{}, stacktrace.Propagate(err, "failed to get user")
	}

	subscriptionAdminID := userID
	subscriptionUserIDs := []int64{userID}
	isFamily := false
	var memberStorageLimit *int64
	if user.FamilyAdminID != nil {
		isFamily = true
		subscriptionAdminID = *user.FamilyAdminID
		familyMembers, err := c.FamilyController.FamilyRepo.GetMembersWithStatus(subscriptionAdminID, repo.ActiveFamilyMemberStatus)
		if err != nil {
			return details.LockerUsageResponse{}, stacktrace.Propagate(err, "failed to fetch family usage scope")
		}
		subscriptionUserIDs = make([]int64, 0, len(familyMembers))
		for _, familyMember := range familyMembers {
			subscriptionUserIDs = append(subscriptionUserIDs, familyMember.MemberUserID)
			if familyMember.MemberUserID == userID && userID != subscriptionAdminID {
				memberStorageLimit = familyMember.StorageLimit
			}
		}
	}

	lockerUsage, err := c.UsageRepo.GetLockerUsage(ctx, subscriptionUserIDs)
	if err != nil {
		return details.LockerUsageResponse{}, stacktrace.Propagate(err, "failed to fetch locker file counts")
	}
	usedStorage, err := c.UsageRepo.GetCombinedUsage(ctx, subscriptionUserIDs)
	if err != nil {
		return details.LockerUsageResponse{}, stacktrace.Propagate(err, "failed to fetch shared storage usage")
	}

	// Reuse upload enforcement's subscription validity and provider grace rules.
	subscription, err := c.BillingController.GetActiveSubscription(subscriptionAdminID)
	subStorage := int64(0)
	if err != nil && !errors.Is(err, ente.ErrNoActiveSubscription) {
		return details.LockerUsageResponse{}, stacktrace.Propagate(err, "failed to fetch subscription")
	}
	if err == nil {
		subStorage = subscription.Storage
	}
	bonus, err := c.UserCacheController.GetActiveStorageBonus(ctx, subscriptionAdminID)
	if err != nil {
		return details.LockerUsageResponse{}, stacktrace.Propagate(err, "failed to fetch storage bonus")
	}
	storageLimit := subStorage + bonus.GetUsableBonus(subStorage)
	remainingStorage := maxInt64(storageLimit-usedStorage, 0)
	if memberStorageLimit != nil {
		memberUsage, err := c.UsageRepo.GetUsage(userID)
		if err != nil {
			return details.LockerUsageResponse{}, stacktrace.Propagate(err, "failed to fetch member storage usage")
		}
		memberRemaining := maxInt64(*memberStorageLimit-memberUsage, 0)
		remainingStorage = minInt64(remainingStorage, memberRemaining)
	}

	isPaid := c.BillingController.HasActiveSelfOrFamilySubscription(subscriptionAdminID, true) == nil
	legacyLimits := controller.GetLockerLimitsForTier(isPaid)
	result := details.LockerUsageResponse{
		QuotaMode:          "sharedStorage",
		IsPaid:             isPaid,
		IsFamily:           isFamily,
		UsedFileCount:      lockerUsage.TotalFileCount,
		FileLimit:          legacyLimits.FileLimit,
		RemainingFileCount: maxInt64(legacyLimits.FileLimit-lockerUsage.TotalFileCount, 0),
		UsedStorage:        usedStorage,
		StorageLimit:       storageLimit,
		RemainingStorage:   remainingStorage,
	}
	for _, userLockerUsage := range lockerUsage.Users {
		if userLockerUsage.UserID == userID {
			result.UserFileCount = userLockerUsage.FileCount
			break
		}
	}
	result.UserStorage, err = c.UsageRepo.GetUsage(userID)
	if err != nil {
		return details.LockerUsageResponse{}, stacktrace.Propagate(err, "failed to fetch user storage usage")
	}
	return result, nil
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func minInt64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}
