"""Sleeps until a local wall time: python3 -I at.py HH:MM[:SS]"""
import datetime, sys, time

parts = [int(x) for x in sys.argv[1].split(":")] + [0]
t = datetime.datetime.now().replace(hour=parts[0], minute=parts[1], second=parts[2], microsecond=0)
time.sleep(max(0.0, (t - datetime.datetime.now()).total_seconds()))
