module cronwatch.dev/go/river

go 1.25.0

require (
	cronwatch.dev/go v0.11.1
	cronwatch.dev/go/robfigcron v0.11.1
	github.com/jackc/pgx/v5 v5.10.0
	github.com/riverqueue/river v0.44.1
	github.com/riverqueue/river/riverdriver/riverpgxv5 v0.44.1
	github.com/riverqueue/river/rivertype v0.44.1
	github.com/robfig/cron/v3 v3.0.1
)

require (
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	github.com/riverqueue/river/riverdriver v0.44.1 // indirect
	github.com/riverqueue/river/rivershared v0.44.1 // indirect
	github.com/tidwall/gjson v1.19.0 // indirect
	github.com/tidwall/match v1.2.0 // indirect
	github.com/tidwall/pretty v1.2.1 // indirect
	github.com/tidwall/sjson v1.2.5 // indirect
	golang.org/x/sync v0.22.0 // indirect
	golang.org/x/text v0.41.0 // indirect
)

replace (
	cronwatch.dev/go => ../
	cronwatch.dev/go/robfigcron => ../robfigcron
)
