package groups

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Service struct {
	pool *pgxpool.Pool
	now  func() time.Time
}

type Config struct {
	Pool *pgxpool.Pool
	Now  func() time.Time
}

func NewService(config Config) (*Service, error) {
	if config.Pool == nil {
		return nil, ErrUnavailable
	}
	now := config.Now
	if now == nil {
		now = time.Now
	}
	return &Service{pool: config.Pool, now: now}, nil
}

func (service *Service) Create(ctx context.Context, principal account.Principal, raw CreateGroupInput) (Group, error) {
	name, err := normalizeRequiredText(raw.Name, MaximumGroupName)
	if err != nil {
		return Group{}, err
	}
	memberIDs, err := normalizeUUIDList(raw.MemberIDs, MaximumInviteBatch)
	if err != nil || len(memberIDs) == 0 {
		return Group{}, ErrInvalidInput
	}
	memberIDs = removeUUID(memberIDs, principal.UserID)
	if len(memberIDs) == 0 {
		return Group{}, ErrInvalidInput
	}

	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Group{}, fmt.Errorf("begin create group: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := validateInvitableUsersTx(ctx, tx, principal.UserID, memberIDs); err != nil {
		return Group{}, err
	}
	conversationID := uuid.New()
	if _, err := tx.Exec(ctx, `
		INSERT INTO conversations(id,type,direct_pair_key,last_sequence,created_at,updated_at)
		VALUES($1,'GROUP',NULL,0,$2,$2)
	`, conversationID, now); err != nil {
		return Group{}, fmt.Errorf("insert group conversation: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO groups(conversation_id,name,announcement,join_mode,created_by_user_id,status,created_at,updated_at)
		VALUES($1,$2,'','INVITE_ONLY',$3,'ACTIVE',$4,$4)
	`, conversationID, name, principal.UserID, now); err != nil {
		return Group{}, fmt.Errorf("insert group metadata: %w", err)
	}
	if err := insertMemberTx(ctx, tx, conversationID, principal.UserID, "OWNER", now); err != nil {
		return Group{}, err
	}
	for _, userID := range memberIDs {
		if err := insertMemberTx(ctx, tx, conversationID, userID, "MEMBER", now); err != nil {
			return Group{}, err
		}
	}
	if err := insertGroupOutboxTx(ctx, tx, conversationID, "GROUP_CREATED", nil, map[string]any{
		"groupId": conversationID.String(), "name": name,
	}, now); err != nil {
		return Group{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Group{}, fmt.Errorf("commit create group: %w", err)
	}
	return service.Get(ctx, principal, conversationID)
}

func (service *Service) Get(ctx context.Context, principal account.Principal, groupID uuid.UUID) (Group, error) {
	if groupID == uuid.Nil {
		return Group{}, ErrNotFound
	}
	return loadGroup(ctx, service.pool, principal.UserID, groupID)
}

func (service *Service) Update(ctx context.Context, principal account.Principal, groupID uuid.UUID, raw UpdateGroupInput) (Group, error) {
	if raw.Name == nil && raw.Announcement == nil && raw.JoinMode == nil {
		return Group{}, ErrInvalidInput
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Group{}, fmt.Errorf("begin update group: %w", err)
	}
	defer tx.Rollback(ctx)

	role, err := requireGroupRoleTx(ctx, tx, principal.UserID, groupID)
	if err != nil {
		return Group{}, err
	}
	if role != "OWNER" && role != "ADMIN" {
		return Group{}, ErrForbidden
	}

	var name, announcement, joinMode string
	if err := tx.QueryRow(ctx, `
		SELECT name,announcement,join_mode FROM groups
		WHERE conversation_id=$1 AND status='ACTIVE' FOR UPDATE
	`, groupID).Scan(&name, &announcement, &joinMode); errors.Is(err, pgx.ErrNoRows) {
		return Group{}, ErrNotFound
	} else if err != nil {
		return Group{}, fmt.Errorf("load group for update: %w", err)
	}
	if raw.Name != nil {
		name, err = normalizeRequiredText(*raw.Name, MaximumGroupName)
		if err != nil {
			return Group{}, err
		}
	}
	if raw.Announcement != nil {
		announcement, err = normalizeOptionalText(*raw.Announcement, MaximumAnnouncement)
		if err != nil {
			return Group{}, err
		}
	}
	if raw.JoinMode != nil {
		joinMode = strings.ToUpper(strings.TrimSpace(*raw.JoinMode))
		if joinMode != "INVITE_ONLY" && joinMode != "APPROVAL" {
			return Group{}, ErrInvalidInput
		}
	}
	if _, err := tx.Exec(ctx, `
		UPDATE groups SET name=$2,announcement=$3,join_mode=$4,updated_at=$5
		WHERE conversation_id=$1 AND status='ACTIVE'
	`, groupID, name, announcement, joinMode, now); err != nil {
		return Group{}, fmt.Errorf("update group metadata: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE conversations SET updated_at=$2 WHERE id=$1`, groupID, now); err != nil {
		return Group{}, fmt.Errorf("touch group conversation: %w", err)
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_UPDATED", nil, map[string]any{
		"groupId": groupID.String(), "name": name,
	}, now); err != nil {
		return Group{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Group{}, fmt.Errorf("commit update group: %w", err)
	}
	return service.Get(ctx, principal, groupID)
}

func (service *Service) CanManageInvites(ctx context.Context, principal account.Principal, groupID uuid.UUID) error {
	role, err := requireGroupRole(ctx, service.pool, principal.UserID, groupID)
	if err != nil {
		return err
	}
	if role != "OWNER" && role != "ADMIN" {
		return ErrForbidden
	}
	return nil
}

func (service *Service) RedeemQRInvite(
	ctx context.Context,
	principal account.Principal,
	groupID uuid.UUID,
	inviterID uuid.UUID,
) (Group, []uuid.UUID, error) {
	if principal.UserID == uuid.Nil || inviterID == uuid.Nil || groupID == uuid.Nil {
		return Group{}, nil, ErrInvalidInput
	}
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Group{}, nil, fmt.Errorf("begin redeem group qr invite: %w", err)
	}
	defer tx.Rollback(ctx)
	joined, err := service.RedeemQRInviteTx(ctx, tx, principal, groupID, inviterID)
	if err != nil {
		return Group{}, nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Group{}, nil, fmt.Errorf("commit qr group join: %w", err)
	}
	group, err := service.Get(ctx, principal, groupID)
	if err != nil {
		return Group{}, nil, err
	}
	if !joined {
		return group, nil, nil
	}
	recipients, err := service.ActiveMemberIDs(ctx, groupID)
	if err != nil {
		return Group{}, nil, err
	}
	return group, recipients, nil
}

func (service *Service) RedeemQRInviteTx(
	ctx context.Context,
	tx pgx.Tx,
	principal account.Principal,
	groupID uuid.UUID,
	inviterID uuid.UUID,
) (bool, error) {
	if principal.UserID == uuid.Nil || inviterID == uuid.Nil || groupID == uuid.Nil {
		return false, ErrInvalidInput
	}
	now := service.now().UTC()
	if err := lockActiveGroupTx(ctx, tx, groupID); err != nil {
		return false, err
	}
	var inviterRole string
	if err := tx.QueryRow(ctx, `
		SELECT role FROM conversation_members
		WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE'
	`, groupID, inviterID).Scan(&inviterRole); errors.Is(err, pgx.ErrNoRows) {
		return false, ErrForbidden
	} else if err != nil {
		return false, fmt.Errorf("validate qr inviter membership: %w", err)
	}
	if inviterRole != "OWNER" && inviterRole != "ADMIN" {
		return false, ErrForbidden
	}
	var alreadyMember bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM conversation_members WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE')
	`, groupID, principal.UserID).Scan(&alreadyMember); err != nil {
		return false, fmt.Errorf("check qr existing member: %w", err)
	}
	if alreadyMember {
		return false, nil
	}
	blocked, err := blockedBetweenTx(ctx, tx, inviterID, principal.UserID)
	if err != nil {
		return false, err
	}
	if blocked {
		return false, ErrForbidden
	}
	var activeUser bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE id=$1 AND status='ACTIVE')`, principal.UserID).Scan(&activeUser); err != nil {
		return false, fmt.Errorf("validate qr join user: %w", err)
	}
	if !activeUser {
		return false, ErrNotFound
	}
	if err := ensureCapacityTx(ctx, tx, groupID, 1); err != nil {
		return false, err
	}
	if err := upsertMemberTx(ctx, tx, groupID, principal.UserID, "MEMBER", now); err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE groups SET updated_at=$2 WHERE conversation_id=$1`, groupID, now); err != nil {
		return false, fmt.Errorf("touch group after qr join: %w", err)
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_MEMBER_ADDED", &principal.UserID, map[string]any{
		"groupId": groupID.String(), "userId": principal.UserID.String(), "source": "QR_INVITE",
	}, now); err != nil {
		return false, err
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_MEMBERS_CHANGED", nil, map[string]any{
		"groupId": groupID.String(), "source": "QR_INVITE",
	}, now); err != nil {
		return false, err
	}
	return true, nil
}

func (service *Service) ActiveMemberIDs(ctx context.Context, groupID uuid.UUID) ([]uuid.UUID, error) {
	rows, err := service.pool.Query(ctx, `
		SELECT cm.user_id
		FROM conversation_members cm
		JOIN groups g ON g.conversation_id=cm.conversation_id
		WHERE cm.conversation_id=$1 AND cm.status='ACTIVE' AND g.status='ACTIVE'
		ORDER BY cm.user_id
	`, groupID)
	if err != nil {
		return nil, fmt.Errorf("list active group member ids: %w", err)
	}
	defer rows.Close()
	items := make([]uuid.UUID, 0)
	for rows.Next() {
		var userID uuid.UUID
		if err := rows.Scan(&userID); err != nil {
			return nil, fmt.Errorf("scan active group member id: %w", err)
		}
		items = append(items, userID)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate active group member ids: %w", err)
	}
	return items, nil
}

func (service *Service) ListMembers(ctx context.Context, principal account.Principal, groupID uuid.UUID) ([]GroupMember, error) {
	if _, err := requireGroupRole(ctx, service.pool, principal.UserID, groupID); err != nil {
		return nil, err
	}
	rows, err := service.pool.Query(ctx, `
		SELECT u.id::text,u.handle_normalized,u.display_name,cm.role,COALESCE(gmp.nickname,''),cm.joined_at
		FROM conversation_members cm
		JOIN users u ON u.id=cm.user_id
		LEFT JOIN group_member_profiles gmp ON gmp.conversation_id=cm.conversation_id AND gmp.user_id=cm.user_id
		WHERE cm.conversation_id=$1 AND cm.status='ACTIVE' AND u.status='ACTIVE'
		ORDER BY CASE cm.role WHEN 'OWNER' THEN 0 WHEN 'ADMIN' THEN 1 ELSE 2 END,cm.joined_at,u.id
	`, groupID)
	if err != nil {
		return nil, fmt.Errorf("list group members: %w", err)
	}
	defer rows.Close()
	items := make([]GroupMember, 0)
	for rows.Next() {
		var item GroupMember
		if err := rows.Scan(&item.User.ID, &item.User.Handle, &item.User.DisplayName, &item.Role, &item.Nickname, &item.JoinedAt); err != nil {
			return nil, fmt.Errorf("scan group member: %w", err)
		}
		item.JoinedAt = item.JoinedAt.UTC()
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate group members: %w", err)
	}
	return items, nil
}

func (service *Service) InviteMembers(ctx context.Context, principal account.Principal, groupID uuid.UUID, raw InviteMembersInput) ([]GroupMember, error) {
	userIDs, err := normalizeUUIDList(raw.UserIDs, MaximumInviteBatch)
	if err != nil || len(userIDs) == 0 {
		return nil, ErrInvalidInput
	}
	userIDs = removeUUID(userIDs, principal.UserID)
	if len(userIDs) == 0 {
		return nil, ErrInvalidInput
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return nil, fmt.Errorf("begin invite group members: %w", err)
	}
	defer tx.Rollback(ctx)
	role, err := requireGroupRoleTx(ctx, tx, principal.UserID, groupID)
	if err != nil {
		return nil, err
	}
	if role != "OWNER" && role != "ADMIN" {
		return nil, ErrForbidden
	}
	if err := lockActiveGroupTx(ctx, tx, groupID); err != nil {
		return nil, err
	}

	active := make(map[uuid.UUID]bool, len(userIDs))
	rows, err := tx.Query(ctx, `
		SELECT user_id FROM conversation_members
		WHERE conversation_id=$1 AND user_id=ANY($2::uuid[]) AND status='ACTIVE'
	`, groupID, userIDs)
	if err != nil {
		return nil, fmt.Errorf("load existing group members: %w", err)
	}
	for rows.Next() {
		var userID uuid.UUID
		if err := rows.Scan(&userID); err != nil {
			rows.Close()
			return nil, fmt.Errorf("scan existing group member: %w", err)
		}
		active[userID] = true
	}
	rows.Close()

	newIDs := make([]uuid.UUID, 0, len(userIDs))
	for _, userID := range userIDs {
		if !active[userID] {
			newIDs = append(newIDs, userID)
		}
	}
	if len(newIDs) == 0 {
		return []GroupMember{}, nil
	}
	if err := validateInvitableUsersTx(ctx, tx, principal.UserID, newIDs); err != nil {
		return nil, err
	}
	if err := ensureCapacityTx(ctx, tx, groupID, len(newIDs)); err != nil {
		return nil, err
	}
	for _, userID := range newIDs {
		if err := upsertMemberTx(ctx, tx, groupID, userID, "MEMBER", now); err != nil {
			return nil, err
		}
		if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_MEMBER_ADDED", &userID, map[string]any{
			"groupId": groupID.String(), "userId": userID.String(),
		}, now); err != nil {
			return nil, err
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE groups SET updated_at=$2 WHERE conversation_id=$1`, groupID, now); err != nil {
		return nil, fmt.Errorf("touch group after invite: %w", err)
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_MEMBERS_CHANGED", nil, map[string]any{"groupId": groupID.String()}, now); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit invite group members: %w", err)
	}
	all, err := service.ListMembers(ctx, principal, groupID)
	if err != nil {
		return nil, err
	}
	wanted := make(map[string]bool, len(newIDs))
	for _, id := range newIDs {
		wanted[id.String()] = true
	}
	result := make([]GroupMember, 0, len(newIDs))
	for _, item := range all {
		if wanted[item.User.ID] {
			result = append(result, item)
		}
	}
	return result, nil
}

func (service *Service) RemoveMember(ctx context.Context, principal account.Principal, groupID, targetUserID uuid.UUID) error {
	if targetUserID == uuid.Nil || targetUserID == principal.UserID {
		return ErrInvalidInput
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return fmt.Errorf("begin remove group member: %w", err)
	}
	defer tx.Rollback(ctx)
	callerRole, err := requireGroupRoleTx(ctx, tx, principal.UserID, groupID)
	if err != nil {
		return err
	}
	if callerRole != "OWNER" && callerRole != "ADMIN" {
		return ErrForbidden
	}
	var targetRole string
	if err := tx.QueryRow(ctx, `
		SELECT role FROM conversation_members
		WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE' FOR UPDATE
	`, groupID, targetUserID).Scan(&targetRole); errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	} else if err != nil {
		return fmt.Errorf("load target group member: %w", err)
	}
	if targetRole == "OWNER" || (callerRole == "ADMIN" && targetRole != "MEMBER") {
		return ErrForbidden
	}
	if _, err := tx.Exec(ctx, `
		UPDATE conversation_members SET status='REMOVED',left_at=$3,is_pinned=false,muted_until=NULL,archived_at=NULL
		WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE'
	`, groupID, targetUserID, now); err != nil {
		return fmt.Errorf("remove group member: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE groups SET updated_at=$2 WHERE conversation_id=$1`, groupID, now); err != nil {
		return fmt.Errorf("touch group after removal: %w", err)
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_MEMBER_REMOVED", &targetUserID, map[string]any{
		"groupId": groupID.String(), "userId": targetUserID.String(),
	}, now); err != nil {
		return err
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_MEMBERS_CHANGED", nil, map[string]any{"groupId": groupID.String()}, now); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit remove group member: %w", err)
	}
	return nil
}

func (service *Service) UpdateMember(ctx context.Context, principal account.Principal, groupID, targetUserID uuid.UUID, raw UpdateMemberInput) (GroupMember, error) {
	if targetUserID == uuid.Nil || (raw.Role == nil && raw.Nickname == nil) {
		return GroupMember{}, ErrInvalidInput
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return GroupMember{}, fmt.Errorf("begin update group member: %w", err)
	}
	defer tx.Rollback(ctx)
	callerRole, err := requireGroupRoleTx(ctx, tx, principal.UserID, groupID)
	if err != nil {
		return GroupMember{}, err
	}
	var targetRole string
	if err := tx.QueryRow(ctx, `
		SELECT role FROM conversation_members
		WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE' FOR UPDATE
	`, groupID, targetUserID).Scan(&targetRole); errors.Is(err, pgx.ErrNoRows) {
		return GroupMember{}, ErrNotFound
	} else if err != nil {
		return GroupMember{}, fmt.Errorf("load member for update: %w", err)
	}
	if raw.Role != nil {
		if callerRole != "OWNER" || targetUserID == principal.UserID || targetRole == "OWNER" {
			return GroupMember{}, ErrForbidden
		}
		role := strings.ToUpper(strings.TrimSpace(*raw.Role))
		if role != "ADMIN" && role != "MEMBER" {
			return GroupMember{}, ErrInvalidInput
		}
		if _, err := tx.Exec(ctx, `UPDATE conversation_members SET role=$3 WHERE conversation_id=$1 AND user_id=$2`, groupID, targetUserID, role); err != nil {
			return GroupMember{}, fmt.Errorf("update group role: %w", err)
		}
	}
	if raw.Nickname != nil {
		if targetUserID != principal.UserID {
			return GroupMember{}, ErrForbidden
		}
		nickname, err := normalizeOptionalText(*raw.Nickname, MaximumNickname)
		if err != nil {
			return GroupMember{}, err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO group_member_profiles(conversation_id,user_id,nickname,updated_at)
			VALUES($1,$2,$3,$4)
			ON CONFLICT(conversation_id,user_id) DO UPDATE SET nickname=EXCLUDED.nickname,updated_at=EXCLUDED.updated_at
		`, groupID, targetUserID, nickname, now); err != nil {
			return GroupMember{}, fmt.Errorf("update group nickname: %w", err)
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE groups SET updated_at=$2 WHERE conversation_id=$1`, groupID, now); err != nil {
		return GroupMember{}, fmt.Errorf("touch group after member update: %w", err)
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_MEMBERS_CHANGED", nil, map[string]any{"groupId": groupID.String()}, now); err != nil {
		return GroupMember{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return GroupMember{}, fmt.Errorf("commit update group member: %w", err)
	}
	members, err := service.ListMembers(ctx, principal, groupID)
	if err != nil {
		return GroupMember{}, err
	}
	for _, item := range members {
		if item.User.ID == targetUserID.String() {
			return item, nil
		}
	}
	return GroupMember{}, ErrNotFound
}

func (service *Service) Leave(ctx context.Context, principal account.Principal, groupID uuid.UUID) error {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return fmt.Errorf("begin leave group: %w", err)
	}
	defer tx.Rollback(ctx)
	role, err := requireGroupRoleTx(ctx, tx, principal.UserID, groupID)
	if err != nil {
		return err
	}
	if role == "OWNER" {
		return ErrConflict
	}
	if _, err := tx.Exec(ctx, `
		UPDATE conversation_members SET status='LEFT',left_at=$3,is_pinned=false,muted_until=NULL,archived_at=NULL
		WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE'
	`, groupID, principal.UserID, now); err != nil {
		return fmt.Errorf("leave group: %w", err)
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_MEMBER_LEFT", &principal.UserID, map[string]any{
		"groupId": groupID.String(), "userId": principal.UserID.String(),
	}, now); err != nil {
		return err
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_MEMBERS_CHANGED", nil, map[string]any{"groupId": groupID.String()}, now); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit leave group: %w", err)
	}
	return nil
}

func (service *Service) TransferOwnership(ctx context.Context, principal account.Principal, groupID uuid.UUID, raw TransferOwnershipInput) (Group, error) {
	targetUserID, err := uuid.Parse(strings.TrimSpace(raw.UserID))
	if err != nil || targetUserID == principal.UserID {
		return Group{}, ErrInvalidInput
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return Group{}, fmt.Errorf("begin transfer group ownership: %w", err)
	}
	defer tx.Rollback(ctx)
	role, err := requireGroupRoleTx(ctx, tx, principal.UserID, groupID)
	if err != nil {
		return Group{}, err
	}
	if role != "OWNER" {
		return Group{}, ErrForbidden
	}
	var targetRole string
	if err := tx.QueryRow(ctx, `
		SELECT role FROM conversation_members
		WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE' FOR UPDATE
	`, groupID, targetUserID).Scan(&targetRole); errors.Is(err, pgx.ErrNoRows) {
		return Group{}, ErrNotFound
	} else if err != nil {
		return Group{}, fmt.Errorf("load ownership target: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE conversation_members
		SET role=CASE WHEN user_id=$2 THEN 'MEMBER' ELSE 'OWNER' END
		WHERE conversation_id=$1 AND user_id IN ($2,$3) AND status='ACTIVE'
	`, groupID, principal.UserID, targetUserID); err != nil {
		return Group{}, fmt.Errorf("transfer group ownership: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE groups SET updated_at=$2 WHERE conversation_id=$1`, groupID, now); err != nil {
		return Group{}, fmt.Errorf("touch group after ownership transfer: %w", err)
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_OWNER_TRANSFERRED", nil, map[string]any{
		"groupId": groupID.String(), "ownerUserId": targetUserID.String(),
	}, now); err != nil {
		return Group{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Group{}, fmt.Errorf("commit transfer group ownership: %w", err)
	}
	return service.Get(ctx, principal, groupID)
}

func (service *Service) Dissolve(ctx context.Context, principal account.Principal, groupID uuid.UUID) error {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return fmt.Errorf("begin dissolve group: %w", err)
	}
	defer tx.Rollback(ctx)
	role, err := requireGroupRoleTx(ctx, tx, principal.UserID, groupID)
	if err != nil {
		return err
	}
	if role != "OWNER" {
		return ErrForbidden
	}
	rows, err := tx.Query(ctx, `SELECT user_id FROM conversation_members WHERE conversation_id=$1 AND status='ACTIVE' FOR UPDATE`, groupID)
	if err != nil {
		return fmt.Errorf("load members for dissolve: %w", err)
	}
	memberIDs := make([]uuid.UUID, 0)
	for rows.Next() {
		var userID uuid.UUID
		if err := rows.Scan(&userID); err != nil {
			rows.Close()
			return fmt.Errorf("scan dissolve member: %w", err)
		}
		memberIDs = append(memberIDs, userID)
	}
	rows.Close()
	if _, err := tx.Exec(ctx, `
		UPDATE groups SET status='DISSOLVED',dissolved_at=$2,updated_at=$2
		WHERE conversation_id=$1 AND status='ACTIVE'
	`, groupID, now); err != nil {
		return fmt.Errorf("dissolve group: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE conversation_members SET status='REMOVED',left_at=$2,is_pinned=false,muted_until=NULL,archived_at=NULL
		WHERE conversation_id=$1 AND status='ACTIVE'
	`, groupID, now); err != nil {
		return fmt.Errorf("remove dissolved group members: %w", err)
	}
	for _, userID := range memberIDs {
		uid := userID
		if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_DISSOLVED", &uid, map[string]any{"groupId": groupID.String()}, now); err != nil {
			return err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit dissolve group: %w", err)
	}
	return nil
}

func (service *Service) CreateJoinRequest(ctx context.Context, principal account.Principal, groupID uuid.UUID, raw CreateJoinRequestInput) (JoinRequest, error) {
	message, err := normalizeOptionalText(raw.Message, MaximumJoinMessage)
	if err != nil {
		return JoinRequest{}, err
	}
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return JoinRequest{}, fmt.Errorf("begin group join request: %w", err)
	}
	defer tx.Rollback(ctx)
	var joinMode string
	var ownerUserID uuid.UUID
	if err := tx.QueryRow(ctx, `
		SELECT g.join_mode,owner.user_id
		FROM groups g
		JOIN conversation_members owner ON owner.conversation_id=g.conversation_id AND owner.role='OWNER' AND owner.status='ACTIVE'
		WHERE g.conversation_id=$1 AND g.status='ACTIVE'
		FOR UPDATE OF g
	`, groupID).Scan(&joinMode, &ownerUserID); errors.Is(err, pgx.ErrNoRows) {
		return JoinRequest{}, ErrNotFound
	} else if err != nil {
		return JoinRequest{}, fmt.Errorf("load group join policy: %w", err)
	}
	if joinMode != "APPROVAL" {
		return JoinRequest{}, ErrForbidden
	}
	var alreadyMember bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM conversation_members WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE')`, groupID, principal.UserID).Scan(&alreadyMember); err != nil {
		return JoinRequest{}, fmt.Errorf("check group membership: %w", err)
	}
	if alreadyMember {
		return JoinRequest{}, ErrAlreadyMember
	}
	if blocked, err := blockedBetweenTx(ctx, tx, principal.UserID, ownerUserID); err != nil {
		return JoinRequest{}, err
	} else if blocked {
		return JoinRequest{}, ErrForbidden
	}
	var item JoinRequest
	if err := tx.QueryRow(ctx, `
		INSERT INTO group_join_requests(conversation_id,requester_user_id,message,status,created_at)
		VALUES($1,$2,$3,'PENDING',$4)
		ON CONFLICT(conversation_id,requester_user_id) WHERE status='PENDING'
		DO UPDATE SET message=EXCLUDED.message
		RETURNING id::text,conversation_id::text,message,status,created_at,resolved_at
	`, groupID, principal.UserID, message, now).Scan(&item.ID, &item.GroupID, &item.Message, &item.Status, &item.CreatedAt, &item.ResolvedAt); err != nil {
		return JoinRequest{}, fmt.Errorf("insert group join request: %w", err)
	}
	if err := loadUserPreviewTx(ctx, tx, principal.UserID, &item.Requester); err != nil {
		return JoinRequest{}, err
	}
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_JOIN_REQUESTED", nil, map[string]any{
		"groupId": groupID.String(), "requestId": item.ID,
	}, now); err != nil {
		return JoinRequest{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return JoinRequest{}, fmt.Errorf("commit group join request: %w", err)
	}
	item.CreatedAt = item.CreatedAt.UTC()
	return item, nil
}

func (service *Service) ListJoinRequests(ctx context.Context, principal account.Principal, groupID uuid.UUID) ([]JoinRequest, error) {
	role, err := requireGroupRole(ctx, service.pool, principal.UserID, groupID)
	if err != nil {
		return nil, err
	}
	if role != "OWNER" && role != "ADMIN" {
		return nil, ErrForbidden
	}
	rows, err := service.pool.Query(ctx, `
		SELECT r.id::text,r.conversation_id::text,u.id::text,u.handle_normalized,u.display_name,r.message,r.status,r.created_at,r.resolved_at,r.resolved_by_user_id::text
		FROM group_join_requests r
		JOIN users u ON u.id=r.requester_user_id
		WHERE r.conversation_id=$1 AND r.status='PENDING'
		ORDER BY r.created_at,r.id
	`, groupID)
	if err != nil {
		return nil, fmt.Errorf("list group join requests: %w", err)
	}
	defer rows.Close()
	items := make([]JoinRequest, 0)
	for rows.Next() {
		var item JoinRequest
		if err := rows.Scan(&item.ID, &item.GroupID, &item.Requester.ID, &item.Requester.Handle, &item.Requester.DisplayName, &item.Message, &item.Status, &item.CreatedAt, &item.ResolvedAt, &item.ResolvedByID); err != nil {
			return nil, fmt.Errorf("scan group join request: %w", err)
		}
		item.CreatedAt = item.CreatedAt.UTC()
		if item.ResolvedAt != nil {
			value := item.ResolvedAt.UTC()
			item.ResolvedAt = &value
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate group join requests: %w", err)
	}
	return items, nil
}

func (service *Service) ResolveJoinRequest(ctx context.Context, principal account.Principal, groupID, requestID uuid.UUID, approve bool) (JoinRequest, error) {
	now := service.now().UTC()
	tx, err := service.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.Serializable})
	if err != nil {
		return JoinRequest{}, fmt.Errorf("begin resolve group join request: %w", err)
	}
	defer tx.Rollback(ctx)
	role, err := requireGroupRoleTx(ctx, tx, principal.UserID, groupID)
	if err != nil {
		return JoinRequest{}, err
	}
	if role != "OWNER" && role != "ADMIN" {
		return JoinRequest{}, ErrForbidden
	}
	var requesterUserID uuid.UUID
	var item JoinRequest
	if err := tx.QueryRow(ctx, `
		SELECT id::text,conversation_id::text,requester_user_id,message,status,created_at,resolved_at
		FROM group_join_requests
		WHERE id=$1 AND conversation_id=$2
		FOR UPDATE
	`, requestID, groupID).Scan(&item.ID, &item.GroupID, &requesterUserID, &item.Message, &item.Status, &item.CreatedAt, &item.ResolvedAt); errors.Is(err, pgx.ErrNoRows) {
		return JoinRequest{}, ErrNotFound
	} else if err != nil {
		return JoinRequest{}, fmt.Errorf("load group join request: %w", err)
	}
	if item.Status != "PENDING" {
		return JoinRequest{}, ErrConflict
	}
	nextStatus := "REJECTED"
	if approve {
		var ownerUserID uuid.UUID
		if err := tx.QueryRow(ctx, `
			SELECT owner.user_id
			FROM conversation_members owner
			JOIN users requester ON requester.id=$2 AND requester.status='ACTIVE'
			WHERE owner.conversation_id=$1 AND owner.role='OWNER' AND owner.status='ACTIVE'
		`, groupID, requesterUserID).Scan(&ownerUserID); errors.Is(err, pgx.ErrNoRows) {
			return JoinRequest{}, ErrNotFound
		} else if err != nil {
			return JoinRequest{}, fmt.Errorf("validate join requester: %w", err)
		}
		if blocked, err := blockedBetweenTx(ctx, tx, requesterUserID, ownerUserID); err != nil {
			return JoinRequest{}, err
		} else if blocked {
			return JoinRequest{}, ErrForbidden
		}
		if err := ensureCapacityTx(ctx, tx, groupID, 1); err != nil {
			return JoinRequest{}, err
		}
		if err := upsertMemberTx(ctx, tx, groupID, requesterUserID, "MEMBER", now); err != nil {
			return JoinRequest{}, err
		}
		nextStatus = "APPROVED"
	}
	if _, err := tx.Exec(ctx, `
		UPDATE group_join_requests SET status=$3,resolved_at=$4,resolved_by_user_id=$5
		WHERE id=$1 AND conversation_id=$2
	`, requestID, groupID, nextStatus, now, principal.UserID); err != nil {
		return JoinRequest{}, fmt.Errorf("resolve group join request: %w", err)
	}
	if err := loadUserPreviewTx(ctx, tx, requesterUserID, &item.Requester); err != nil {
		return JoinRequest{}, err
	}
	resolver := principal.UserID.String()
	item.Status = nextStatus
	item.ResolvedAt = &now
	item.ResolvedByID = &resolver
	if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_JOIN_REQUEST_RESOLVED", &requesterUserID, map[string]any{
		"groupId": groupID.String(), "requestId": item.ID, "status": nextStatus,
	}, now); err != nil {
		return JoinRequest{}, err
	}
	if approve {
		if err := insertGroupOutboxTx(ctx, tx, groupID, "GROUP_MEMBERS_CHANGED", nil, map[string]any{"groupId": groupID.String()}, now); err != nil {
			return JoinRequest{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return JoinRequest{}, fmt.Errorf("commit resolve group join request: %w", err)
	}
	item.CreatedAt = item.CreatedAt.UTC()
	return item, nil
}

func loadGroup(ctx context.Context, queryer interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, userID, groupID uuid.UUID) (Group, error) {
	var item Group
	err := queryer.QueryRow(ctx, `
		SELECT g.conversation_id::text,g.name,g.announcement,g.join_mode,g.status,
		       (SELECT count(*) FROM conversation_members m WHERE m.conversation_id=g.conversation_id AND m.status='ACTIVE'),
		       owner.user_id::text,mine.role,COALESCE(profile.nickname,''),g.created_at,g.updated_at,g.dissolved_at
		FROM groups g
		JOIN conversation_members mine ON mine.conversation_id=g.conversation_id AND mine.user_id=$2 AND mine.status='ACTIVE'
		JOIN conversation_members owner ON owner.conversation_id=g.conversation_id AND owner.role='OWNER' AND owner.status='ACTIVE'
		LEFT JOIN group_member_profiles profile ON profile.conversation_id=g.conversation_id AND profile.user_id=$2
		WHERE g.conversation_id=$1 AND g.status='ACTIVE'
	`, groupID, userID).Scan(&item.ID, &item.Name, &item.Announcement, &item.JoinMode, &item.Status, &item.MemberCount, &item.OwnerUserID, &item.MyRole, &item.MyNickname, &item.CreatedAt, &item.UpdatedAt, &item.DissolvedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Group{}, ErrNotFound
	}
	if err != nil {
		return Group{}, fmt.Errorf("load group: %w", err)
	}
	item.CreatedAt = item.CreatedAt.UTC()
	item.UpdatedAt = item.UpdatedAt.UTC()
	return item, nil
}

func requireGroupRole(ctx context.Context, queryer interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, userID, groupID uuid.UUID) (string, error) {
	var role string
	err := queryer.QueryRow(ctx, `
		SELECT cm.role
		FROM conversation_members cm
		JOIN groups g ON g.conversation_id=cm.conversation_id
		WHERE cm.conversation_id=$1 AND cm.user_id=$2 AND cm.status='ACTIVE' AND g.status='ACTIVE'
	`, groupID, userID).Scan(&role)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", fmt.Errorf("authorize group member: %w", err)
	}
	return role, nil
}

func requireGroupRoleTx(ctx context.Context, tx pgx.Tx, userID, groupID uuid.UUID) (string, error) {
	return requireGroupRole(ctx, tx, userID, groupID)
}

func lockActiveGroupTx(ctx context.Context, tx pgx.Tx, groupID uuid.UUID) error {
	var status string
	if err := tx.QueryRow(ctx, `SELECT status FROM groups WHERE conversation_id=$1 FOR UPDATE`, groupID).Scan(&status); errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	} else if err != nil {
		return fmt.Errorf("lock group: %w", err)
	}
	if status != "ACTIVE" {
		return ErrNotFound
	}
	return nil
}

func insertMemberTx(ctx context.Context, tx pgx.Tx, groupID, userID uuid.UUID, role string, now time.Time) error {
	if _, err := tx.Exec(ctx, `
		INSERT INTO conversation_members(conversation_id,user_id,role,status,joined_at,left_at,last_read_sequence,is_pinned)
		VALUES($1,$2,$3,'ACTIVE',$4,NULL,0,false)
	`, groupID, userID, role, now); err != nil {
		return fmt.Errorf("insert group member: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO group_member_profiles(conversation_id,user_id,nickname,updated_at)
		VALUES($1,$2,'',$3)
	`, groupID, userID, now); err != nil {
		return fmt.Errorf("insert group member profile: %w", err)
	}
	return nil
}

func upsertMemberTx(ctx context.Context, tx pgx.Tx, groupID, userID uuid.UUID, role string, now time.Time) error {
	if _, err := tx.Exec(ctx, `
		INSERT INTO conversation_members(conversation_id,user_id,role,status,joined_at,left_at,last_read_sequence,is_pinned)
		VALUES($1,$2,$3,'ACTIVE',$4,NULL,0,false)
		ON CONFLICT(conversation_id,user_id) DO UPDATE SET
			role=EXCLUDED.role,status='ACTIVE',joined_at=EXCLUDED.joined_at,left_at=NULL,
			last_read_sequence=0,is_pinned=false,muted_until=NULL,archived_at=NULL,hidden_through_sequence=NULL
	`, groupID, userID, role, now); err != nil {
		return fmt.Errorf("upsert group member: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO group_member_profiles(conversation_id,user_id,nickname,updated_at)
		VALUES($1,$2,'',$3)
		ON CONFLICT(conversation_id,user_id) DO UPDATE SET nickname='',updated_at=EXCLUDED.updated_at
	`, groupID, userID, now); err != nil {
		return fmt.Errorf("upsert group member profile: %w", err)
	}
	return nil
}

func ensureCapacityTx(ctx context.Context, tx pgx.Tx, groupID uuid.UUID, additional int) error {
	if err := lockActiveGroupTx(ctx, tx, groupID); err != nil {
		return err
	}
	var count int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM conversation_members WHERE conversation_id=$1 AND status='ACTIVE'`, groupID).Scan(&count); err != nil {
		return fmt.Errorf("count group members: %w", err)
	}
	if count+additional > MaximumGroupMembers {
		return ErrMemberLimit
	}
	return nil
}

func validateInvitableUsersTx(ctx context.Context, tx pgx.Tx, inviterID uuid.UUID, userIDs []uuid.UUID) error {
	for _, userID := range userIDs {
		if userID == uuid.Nil || userID == inviterID {
			return ErrInvalidInput
		}
		var active, contact, blocked bool
		if err := tx.QueryRow(ctx, `
			SELECT
				EXISTS(SELECT 1 FROM users WHERE id=$2 AND status='ACTIVE'),
				EXISTS(SELECT 1 FROM contacts WHERE owner_user_id=$1 AND contact_user_id=$2),
				EXISTS(SELECT 1 FROM blocks WHERE (owner_user_id=$1 AND blocked_user_id=$2) OR (owner_user_id=$2 AND blocked_user_id=$1))
		`, inviterID, userID).Scan(&active, &contact, &blocked); err != nil {
			return fmt.Errorf("validate group invitee: %w", err)
		}
		if !active {
			return ErrNotFound
		}
		if !contact || blocked {
			return ErrForbidden
		}
	}
	return nil
}

func blockedBetweenTx(ctx context.Context, tx pgx.Tx, a, b uuid.UUID) (bool, error) {
	var blocked bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM blocks WHERE (owner_user_id=$1 AND blocked_user_id=$2) OR (owner_user_id=$2 AND blocked_user_id=$1))
	`, a, b).Scan(&blocked); err != nil {
		return false, fmt.Errorf("check group block relationship: %w", err)
	}
	return blocked, nil
}

func insertGroupOutboxTx(ctx context.Context, tx pgx.Tx, groupID uuid.UUID, eventType string, targetUserID *uuid.UUID, payload map[string]any, now time.Time) error {
	raw, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal group outbox payload: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO outbox_events(aggregate_type,aggregate_id,event_type,conversation_id,target_user_id,payload_json,created_at,available_at)
		VALUES('GROUP',$1,$2,$1,$3,$4::jsonb,$5,$5)
	`, groupID, eventType, targetUserID, string(raw), now); err != nil {
		return fmt.Errorf("insert group outbox event: %w", err)
	}
	return nil
}

func loadUserPreviewTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, output *UserPreview) error {
	if err := tx.QueryRow(ctx, `SELECT id::text,handle_normalized,display_name FROM users WHERE id=$1 AND status='ACTIVE'`, userID).Scan(&output.ID, &output.Handle, &output.DisplayName); errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	} else if err != nil {
		return fmt.Errorf("load group user preview: %w", err)
	}
	return nil
}

func normalizeUUIDList(raw []string, limit int) ([]uuid.UUID, error) {
	if len(raw) > limit {
		return nil, ErrInvalidInput
	}
	seen := make(map[uuid.UUID]struct{}, len(raw))
	result := make([]uuid.UUID, 0, len(raw))
	for _, value := range raw {
		parsed, err := uuid.Parse(strings.TrimSpace(value))
		if err != nil || parsed == uuid.Nil {
			return nil, ErrInvalidInput
		}
		if _, ok := seen[parsed]; ok {
			continue
		}
		seen[parsed] = struct{}{}
		result = append(result, parsed)
	}
	return result, nil
}

func removeUUID(values []uuid.UUID, target uuid.UUID) []uuid.UUID {
	result := values[:0]
	for _, value := range values {
		if value != target {
			result = append(result, value)
		}
	}
	return result
}

func normalizeRequiredText(raw string, max int) (string, error) {
	value := strings.TrimSpace(raw)
	if value == "" || utf8.RuneCountInString(value) > max {
		return "", ErrInvalidInput
	}
	return value, nil
}

func normalizeOptionalText(raw string, max int) (string, error) {
	value := strings.TrimSpace(raw)
	if utf8.RuneCountInString(value) > max {
		return "", ErrInvalidInput
	}
	return value, nil
}
