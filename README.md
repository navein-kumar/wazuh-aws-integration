# Wazuh AWS integration

Two additions for a Wazuh manager that collects AWS logs with the built in AWS module.

| Folder | What it is |
|---|---|
| [aws-loop](aws-loop/) | a small scheduler that runs the Wazuh AWS module one bucket at a time, in isolation, as a systemd service |
| [mongodb-atlas-decoder](mongodb-atlas-decoder/) | decoder and rules for MongoDB Atlas logs delivered through S3 |

## The problem with the Wazuh AWS module

The Wazuh AWS module (`wodle name="aws-s3"`) works well for one or two buckets. With many buckets and
services on one manager it shows these limits:

1. **One shared state database.** Every bucket type writes its markers into the same SQLite file,
   `s3_cloudtrail.db`. SQLite allows one writer at a time and the module has no retry, so when two runs
   overlap the second one dies with "database is locked" and pulls nothing.
2. **One long run blocks the rest.** The module runs the configured blocks in order. A bucket with
   millions of objects, or a CloudWatch log group with thousands of streams, keeps the others waiting
   for hours.
3. **Markers are saved only at the end.** A run that is killed, times out or is interrupted loses the
   whole run and reads the same files again next time, sending duplicate events.
4. **No visibility.** There is no record of which bucket ran, how long it took, whether it failed on
   permissions, or whether it is hanging. The only trace is `ossec.log` at debug level.

Wazuh itself has no setting that changes any of this.

## The idea behind aws-loop

Keep the Wazuh module exactly as it is and change only how it is scheduled.

- **One config file, one line per bucket or service**, with the same arguments the module accepts
  on the command line. A line that works by hand works in the loop.
- **Each line runs in its own environment.** The loop builds a folder per line that links to
  `/var/ossec` but has private copies of the module entry point and of the state databases. Jobs
  never share a SQLite file, so they never lock each other, and any number can run at the same time.
- **Rounds, not a fixed schedule.** The loop runs the lines one after another, waits two minutes,
  and starts again. A job still running after five minutes is left in the background and the loop
  moves on; it is picked up again when it finishes. A job whose output stops for thirty minutes is
  killed as stuck, and every job has a six hour hard limit.
- **Every result is logged as JSON.** One line per job with the result (`ok`, `empty`, `fail`,
  `denied` for permission or credential errors, `locked`, `stalled`, `killed`), plus one health line
  per round. Wazuh reads that file and raises alerts on failures, so problems show up in the
  dashboard instead of in a debug log.
- **A service, not a cron job.** `bash aws-loop.sh -i` installs it under `/opt/aws-loop`, enables it
  at boot and starts it. Named instances (`-i name`) run in parallel for large environments.

The loop is one bash script, one config file and one rules file. See the
[aws-loop README](aws-loop/README.md) for install and usage.

## MongoDB Atlas decoder

Atlas log export writes each mongod line as a JSON string inside a JSON envelope. Wazuh's JSON
decoder does not parse a JSON string nested in JSON, so the inner fields were invisible to rules.
The folder [mongodb-atlas-decoder](mongodb-atlas-decoder/) offers two ways to handle that:

- `local_decoder_mongodb_atlas.xml` with `local_rules_mongodb_atlas_decoder.xml`: sibling decoders
  under the built in `json` decoder, as described in the Wazuh documentation, read the inner fields
  out with regex and publish them as `mongodb.*` fields (user, client address, database, connection
  details, slow query details, audit details). Rules show those values and can correlate on them.
- `local_rules_mongodb_atlas_simple.xml` alone: no decoder, the rules match text inside the `aws.log`
  string, the approach used in the Wazuh blog on monitoring MongoDB Atlas. Nothing to maintain, but
  no fields, so descriptions cannot show the user or address.

Use one or the other, not both. Install notes are in the header of each file.
