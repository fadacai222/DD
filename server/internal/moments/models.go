package moments

import (
	"errors"
	"time"
)

var (
	ErrUnavailable  = errors.New("moments service unavailable")
	ErrInvalidInput = errors.New("invalid moment input")
	ErrNotFound     = errors.New("moment not found")
	ErrForbidden    = errors.New("moment operation forbidden")
	ErrConflict     = errors.New("moment state conflict")
)

const (
	VisibilityAllContacts = "ALL_CONTACTS"
	VisibilityPrivate     = "PRIVATE"
	VisibilityExclude     = "EXCLUDE"
)

type UserPreview struct {
	ID          string `json:"id"`
	Handle      string `json:"handle"`
	DisplayName string `json:"displayName"`
}

type Comment struct {
	ID               string      `json:"id"`
	Author           UserPreview `json:"author"`
	ReplyToCommentID *string     `json:"replyToCommentId,omitempty"`
	Text             string      `json:"text"`
	CreatedAt        time.Time   `json:"createdAt"`
}

type Moment struct {
	ID         string        `json:"id"`
	Author     UserPreview   `json:"author"`
	Text       string        `json:"text"`
	Visibility string        `json:"visibility"`
	MediaIDs   []string      `json:"mediaIds"`
	LikeUsers  []UserPreview `json:"likeUsers"`
	Comments   []Comment     `json:"comments"`
	LikedByMe  bool          `json:"likedByMe"`
	CreatedAt  time.Time     `json:"createdAt"`
}

type CreateInput struct {
	Text              string   `json:"text"`
	MediaIDs          []string `json:"mediaIds"`
	Visibility        string   `json:"visibility"`
	VisibilityUserIDs []string `json:"visibilityUserIds"`
}

type CommentInput struct {
	Text             string  `json:"text"`
	ReplyToCommentID *string `json:"replyToCommentId,omitempty"`
}

type PreferenceInput struct {
	HideTarget     bool `json:"hideTarget"`
	HideFromTarget bool `json:"hideFromTarget"`
}

type Preference struct {
	Target         UserPreview `json:"target"`
	HideTarget     bool        `json:"hideTarget"`
	HideFromTarget bool        `json:"hideFromTarget"`
	UpdatedAt      time.Time   `json:"updatedAt"`
}

type Profile struct {
	User          UserPreview `json:"user"`
	CoverMediaID  string      `json:"coverMediaId,omitempty"`
	CoverRevision int64       `json:"coverRevision"`
	CanEdit       bool        `json:"canEdit"`
}

type UpdateProfileInput struct {
	CoverMediaID string `json:"coverMediaId"`
}
