package groups

import (
	"errors"
	"time"
)

var (
	ErrUnavailable   = errors.New("groups service unavailable")
	ErrInvalidInput  = errors.New("invalid group input")
	ErrNotFound      = errors.New("group resource not found")
	ErrForbidden     = errors.New("group operation forbidden")
	ErrConflict      = errors.New("group state conflict")
	ErrMemberLimit   = errors.New("group member limit reached")
	ErrAlreadyMember = errors.New("user is already an active group member")
)

const (
	MaximumGroupMembers = 500
	MaximumInviteBatch  = 100
	MaximumGroupName    = 80
	MaximumAnnouncement = 1000
	MaximumNickname     = 80
	MaximumJoinMessage  = 200
)

type UserPreview struct {
	ID          string `json:"id"`
	Handle      string `json:"handle"`
	DisplayName string `json:"displayName"`
}

type Group struct {
	ID             string     `json:"id"`
	Name           string     `json:"name"`
	Announcement   string     `json:"announcement"`
	JoinMode       string     `json:"joinMode"`
	Status         string     `json:"status"`
	MemberCount    int        `json:"memberCount"`
	AvatarMediaID  string     `json:"avatarMediaId,omitempty"`
	AvatarRevision int64      `json:"avatarRevision"`
	OwnerUserID    string     `json:"ownerUserId"`
	MyRole         string     `json:"myRole"`
	MyNickname     string     `json:"myNickname"`
	CreatedAt      time.Time  `json:"createdAt"`
	UpdatedAt      time.Time  `json:"updatedAt"`
	DissolvedAt    *time.Time `json:"dissolvedAt,omitempty"`
}

type GroupMember struct {
	User     UserPreview `json:"user"`
	Role     string      `json:"role"`
	Nickname string      `json:"nickname"`
	JoinedAt time.Time   `json:"joinedAt"`
}

type JoinRequest struct {
	ID           string      `json:"id"`
	GroupID      string      `json:"groupId"`
	Requester    UserPreview `json:"requester"`
	Message      string      `json:"message"`
	Status       string      `json:"status"`
	CreatedAt    time.Time   `json:"createdAt"`
	ResolvedAt   *time.Time  `json:"resolvedAt,omitempty"`
	ResolvedByID *string     `json:"resolvedByUserId,omitempty"`
}

type CreateGroupInput struct {
	Name      string   `json:"name"`
	MemberIDs []string `json:"memberIds"`
}

type UpdateGroupInput struct {
	Name          *string `json:"name"`
	Announcement  *string `json:"announcement"`
	JoinMode      *string `json:"joinMode"`
	AvatarMediaID *string `json:"avatarMediaId"`
}

func (input UpdateGroupInput) hasChanges() bool {
	return input.Name != nil ||
		input.Announcement != nil ||
		input.JoinMode != nil ||
		input.AvatarMediaID != nil
}

type InviteMembersInput struct {
	UserIDs []string `json:"userIds"`
}

type UpdateMemberInput struct {
	Role     *string `json:"role"`
	Nickname *string `json:"nickname"`
}

type TransferOwnershipInput struct {
	UserID string `json:"userId"`
}

type CreateJoinRequestInput struct {
	Message string `json:"message"`
}
