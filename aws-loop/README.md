# aws-loop

Runs the Wazuh AWS module for every line in a config file, one after another, forever.
Each line has its own state, so jobs never lock each other.

## Files

| File | Purpose |
|---|---|
| aws-loop.sh | the script, also installs itself as a service |
| aws-jobs.conf | one line per bucket, log group or queue |
| aws-loop-rules.xml | Wazuh rules for the loop's own log |
| verify.txt | manual test command per service |

## Install

Unzip on the manager, then:

```
cd aws-loop
bash aws-loop.sh -i
```

Installed to `/opt/aws-loop/`, service `aws-loop`, enabled at boot.
Logs: `/var/log/aws-loop/aws-loop.log` and `aws-loop.json`.

Rules, once: add the `<localfile>` block from the top of `aws-loop-rules.xml` to
`ossec.conf`, copy the rules to `/var/ossec/etc/rules/`, then
`systemctl restart wazuh-manager`.

## Jobs

Edit `/opt/aws-loop/aws-jobs.conf`. Remove `#` to enable a line, replace the names.
One space between arguments. Changes are picked up at the next round, no restart needed.

```
--bucket cloudtrail-bucket --type cloudtrail --regions ap-south-1 --only_logs_after 2026-SEP-18
```

Test a line by hand first with the command in `verify.txt`.

## Service

```
systemctl status aws-loop
systemctl restart aws-loop
systemctl stop aws-loop
bash /opt/aws-loop/aws-loop.sh -s      # last results and health
bash /opt/aws-loop/aws-loop.sh -u      # remove the service, keep files
```

## More instances

Split many buckets across services that run in parallel:

```
bash /opt/aws-loop/aws-loop.sh -i bucket1
```

Creates `/opt/aws-loop/bucket1/aws-jobs.conf` and service `aws-loop-bucket1`.
Put each line in one instance only. `bash /opt/aws-loop/aws-loop.sh -l` lists them.

## Timers

At the top of `aws-loop.sh`, seconds. Restart the service after a change.

| Setting | Default | Meaning |
|---|---|---|
| WAIT | 120 | pause between rounds |
| SOFT | 300 | job moved to background, loop continues |
| STALL | 1800 | job killed when its output stops growing |
| MAX_RUN | 21600 | job killed no matter what |

## Results

In `aws-loop.json`, one line per job.

| Result | Meaning |
|---|---|
| ok | finished, new logs sent |
| empty | finished, nothing new in the bucket |
| fail | module error, see the `error` field |
| denied | AWS refused: permission or credentials |
| locked | state database busy, retried next round |
| detached | still running after SOFT, moved to background |
| deferred | skipped this round, its background run is still going |
| stalled | killed: no output for STALL seconds, it was stuck |
| killed | killed: ran longer than MAX_RUN |
