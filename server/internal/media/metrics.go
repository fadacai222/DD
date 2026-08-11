package media

import "time"

type ObjectStoreObserver interface {
	ObserveObjectStorage(operation string, duration time.Duration, err error)
}
