package push

import "context"

type Provider interface {
	Send(ctx context.Context, delivery Delivery) (ProviderResult, error)
}

type Providers struct {
	FCM         Provider
	APNS        Provider
	UnifiedPush Provider
}

func (providers Providers) For(name string) Provider {
	switch normalizeProvider(name) {
	case ProviderFCM:
		return providers.FCM
	case ProviderAPNS:
		return providers.APNS
	case ProviderUnifiedPush:
		return providers.UnifiedPush
	default:
		return nil
	}
}
