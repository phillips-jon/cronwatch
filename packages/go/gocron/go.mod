module cronwatch.dev/go/gocron

go 1.25.0

require (
	cronwatch.dev/go v0.12.4
	cronwatch.dev/go/robfigcron v0.12.4
	github.com/go-co-op/gocron/v2 v2.21.0
	github.com/google/uuid v1.6.0
	github.com/robfig/cron/v3 v3.0.1
)

require github.com/jonboulle/clockwork v0.5.0

replace (
	cronwatch.dev/go => ../
	cronwatch.dev/go/robfigcron => ../robfigcron
)
