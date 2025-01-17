import os
import sys
from pathlib import Path
from datetime import datetime, timezone, timedelta

def log(s):
	print(s, file=sys.stderr)
	sys.stderr.flush()

def bail(s, exitcode = 1):
	log(f"FAIL: {s}")
	sys.exit(exitcode)

def env_get(k):
	if not k in os.environ:
		bail(f"Missing environment variable: {k}")
	v = os.environ[k]
	if not isinstance(v, str):
		bail(f"Environment variable not a string: {k}:{v}")
	return v

def env_get_or_none(k):
	if not k in os.environ:
		return None
	v = os.environ[k]
	if not isinstance(v, str):
		return None
	if len(v) == 0:
		return None
	return v

def env_get_dir_or_none(k):
	v = env_get_or_none(k)
	if not v:
		return None
	path = Path(v)
	if not path.is_dir():
		return None
	return v

def env_get_dir(k):
	v = env_get(k)
	path = Path(v)
	if not path.is_dir():
		bail(f"Environment variable not a directory: {k}:{v}")
	return v

def env_get_file(k):
	v = env_get(k)
	path = Path(v)
	if not path.is_file():
		bail(f"Environment variable not a file: {k}:{v}")
	return v

def dict_val_or(d, k, o):
	if k not in d:
		return o
	return d[k]

def dict_pop_or(d, k, o):
	if k not in d:
		return o
	return d.pop(k)

# Given a dict, extract whichever of 'years', 'months', 'weeks', 'days',
# 'hours', 'minutes', 'seconds' are defined (as integers) and return a
# timedelta corresponding to the aggregate total.
def dict_timedelta(d):
	def get_int_or_none(k):
		ret = dict_val_or(d, k, None)
		if ret and not isinstance(ret, int):
			bail(f"Wrong type for {k} property: {type(ret)},{ret}")
		return ret
	td = timedelta()
	conf_years = get_int_or_none('years')
	conf_months = get_int_or_none('months')
	conf_weeks = get_int_or_none('weeks')
	conf_days = get_int_or_none('days')
	conf_hours = get_int_or_none('hours')
	conf_minutes = get_int_or_none('minutes')
	conf_seconds = get_int_or_none('seconds')
	if conf_years:
		td += timedelta(days = conf_years * 365)
	if conf_months:
		td += timedelta(days = conf_months * 28)
	if conf_weeks:
		td += timedelta(days = conf_weeks * 7)
	if conf_days:
		td += timedelta(days = conf_days)
	if conf_hours:
		td += timedelta(hours = conf_hours)
	if conf_minutes:
		td += timedelta(minutes = conf_minutes)
	if conf_seconds:
		td += timedelta(seconds = conf_seconds)
	return td

# Given a datetime, produce a string of the form "YYYYMMDDhhmmss" that can
# be used in a filename/path. This gives 1-second granularity and gives
# useful outcomes when such strings get sorted alphabetically.
def datetime2hint(dt):
	s = f"{dt.year:04}{dt.month:02}{dt.day:02}"
	s += f"{dt.hour:02}{dt.minute:02}{dt.second:02}"
	return s
