package robfigcron

import (
	"errors"
	"reflect"
	"runtime"
	"strings"

	cronwatch "cronwatch.dev/go"
	"cronwatch.dev/go/bridge"
	"github.com/robfig/cron/v3"
)

// named is a job given a name and options by Named.
type named struct {
	cron.Job
	name    string
	options []cronwatch.JobOption
}

// Named gives a robfig/cron job its CronWatch job's name and options, for a
// job whose own name will not do (a closure, a type used twice) or that
// needs options of its own:
//
//	c.AddJob("0 2 * * *", robfigcron.Named("nightly-report", cron.FuncJob(report), cronwatch.Grace("15m")))
func Named(name string, job cron.Job, options ...cronwatch.JobOption) cron.Job {
	return &named{Job: job, name: name, options: options}
}

// nameOf is a job's name (see the package's documentation for the rule),
// and the options Named gave it.
func nameOf(job cron.Job) (string, []cronwatch.JobOption, error) {
	switch j := job.(type) {
	case *named:
		return j.name, j.options, nil
	case *funcJob:
		return j.name, j.options, nil
	case cron.FuncJob:
		f := runtime.FuncForPC(reflect.ValueOf(j).Pointer())
		if f == nil {
			return "", nil, errors.New("is a function the runtime cannot name; wrap it in robfigcron.Named")
		}
		name, err := bridge.FuncName(f.Name())
		if err != nil {
			return "", nil, errors.New(err.Error() + "; wrap it in robfigcron.Named")
		}
		return name, nil, nil
	}
	t := reflect.TypeOf(job)
	for t != nil && t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	if t == nil || t.Name() == "" {
		return "", nil, errors.New("has no type name to name its job after; wrap it in robfigcron.Named")
	}
	name := t.Name()
	if pkg := t.PkgPath(); pkg != "" {
		name = pkg[strings.LastIndex(pkg, "/")+1:] + "." + name
	}
	if !bridge.ValidName(name) {
		return "", nil, errors.New("is named " + name + ", which is not a CronWatch job name; wrap it in robfigcron.Named")
	}
	return name, nil, nil
}
