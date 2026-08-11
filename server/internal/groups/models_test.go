package groups

import "testing"

func TestUpdateGroupInputHasChanges(t *testing.T) {
	avatarMediaID := "8c40d6ba-d4e4-4a78-b3b6-4f86850df29e"
	emptyAvatarMediaID := ""
	name := "测试群"

	tests := []struct {
		name  string
		input UpdateGroupInput
		want  bool
	}{
		{name: "empty", input: UpdateGroupInput{}, want: false},
		{name: "name", input: UpdateGroupInput{Name: &name}, want: true},
		{name: "avatar only", input: UpdateGroupInput{AvatarMediaID: &avatarMediaID}, want: true},
		{name: "remove avatar only", input: UpdateGroupInput{AvatarMediaID: &emptyAvatarMediaID}, want: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := test.input.hasChanges(); got != test.want {
				t.Fatalf("hasChanges()=%v want %v", got, test.want)
			}
		})
	}
}
