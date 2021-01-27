# Jamulus Jam Exporter

## Features:

- **Automated management of multi-track recording files from Jamulus server**
    - can be very high in quality - audio only made one trip through internet
    - separate tracks allow mixing later
- **Creates an opus-compressed zip archive of a multi-track recording session**"
    - Opus offers huge file size reduction while maintaining high quality
    - Need to use Reaper to mix (very good low-cost $60 DAW with free trial)
- **AWS S3 Bucket upload capability**
    - low-cost serverless storage
    - for automated file management, store in a publicly browsable bucket (see link below)
    - Set a lifecycle policy for automatic deletion of recordings after x days
- **publish-recordings.sh is the only script required for operation**
    - it immediately returns without doing anything if server is in use
    - requires a crontab entry to call it periodically
    - no dependency on inotify-publisher.sh which is now deprecated.
    - parameters should be set in config file /etc/publish-recordings.conf or command line.  Editing the script file publish-recordings.sh should not be requilred.

_General note:_

This comprises one primary script:
* A bash script to apply some judicious rules and compression before uploading the recordings offsite

## Configuration
The configuration file /etc/publish-recordings.conf may contain the following:
```
S3_BUCKET=<s3-bucket-name>                                # S3 bucket name if writing to S3
PREFIX=jamulus                                            # object name prefix if writing to S3
RECORDING_HOST_DIR=user@hostname:/home/user/recordings/   # scp target if using scp instead of S3
SSH_KEY=/root/.ssh/user-private-key.pem                   # ssh key for target user if using scp (with chmod 600 permissions)
RECORDING_DIR=/var/recordings                             # recording dir used by Jamulus server
JAMULUS_STATUSPAGE=/tmp/jamulus-server-status.html        # html status page created by Jamulus server
NO_CLIENT_CONNECTED="No client connected"                 # idle message to check for in status page
ZIP_PASSWORD=secret_password                              # optional password for zip archive
```

I'm not sure if the status file entry `NO_CLIENT_CONNECT` gets translated - if so, the local value is needed here.

## Crontab entry required
Example: call every 10 mins; if server is idle, publish any recordings that exist  
```
*/10 * * * * export HOME=/root; /bin/bash /usr/local/bin/publish-recordings.sh >> /var/log/publish-recordings.log 2>&1
```

## publish-recordings.sh prepare and upload script
**NOTE** PLEASE read and understand, at least basically, what this does _before_ using it.  It makes _destructive edits_
to recordings that you might not want.

### What it does
Given the right `RECORDING_DIR`, this iterates over all subdirectories, looking for Reaper RPP files.
(Currently, the Audacity LOF files are ignored and become wrong.)

The logical processing is as follows.

For each RPP file, the WAV files are examined to determine their audio length and (EBU) volume.  Where the file
is considered "too short" or "too quiet", it is removed (deleted on disk and edited out of the RPP file).
Retained files then have audio compression applied, updating the RPP file with the new name (i.e. WAV -> OPUS).
Any _track_ that now has no entries is also removed.  If the project has no tracks, the recording directory is deleted.

After the above processing, any remaining recording directory gets zipped (without the broken LOF)
and uploaded to `RECORDING_HOST_DIR` or AWS `S3_BUCKET`

### Prerequisites

`apt-get install ffmpeg zip awscli   # for Debian`

The FFMpeg suite - both `ffprobe` and `ffmpeg` itself are used.
* https://ffmpeg.org/

It also uses `zip`.
* http://infozip.sourceforge.net/

Most distributions provide versions that will be adequate.

AWS S3 upload requires `awscli` installed.

AWS S3 upload also requires:
- an s3 bucket (see link to guide above)
    - See this guide to set up a browsable public bucket: [https://github.com/rufuspollock/s3-bucket-listing](https://github.com/rufuspollock/s3-bucket-listing)
    - Set a lifecycle policy for automatic deletion of recordings after x days
    - Provides a low-cost unattended way to manage recordings
- AWS user credentials with access to the bucket
    - create a user specifically for this purpose
    - give this user permissions only for this S3 bucket
    - create an AWS key for this user
- AWS cli on server needs to be configure with the key created above, also the default access region.
- test from command line with `aws s3 ls s3://<bucket-name>`

The script off-sites the recordings - `RECORDING_HOST_DIR` is the target if using scp.  It uses `scp` as root when running the script.
 that will be the `User=` user.  Make sure you have installed
that user's public key in your hosting provider's `authorized_keys` (using the expected key type).


## recover-recording.sh
Also included is a "recovery mode" script.  This helps you recreate any lost Reaper RPP or Audacity LOF
project files from a Jamulus recording directory.  There is a `--help` option that provides the full syntax.

The intent of this script is to take an existing collection of Jamulus recorded WAVE files and generate the
Reaper RPP and Audacity LOF project files that match the one the server should have created.
It may sometimes be needed, for example when the server fails to terminate the recording correctly
(as that is when the project files gets written).

The script should be run from the directory containing the "failed" recording.
By default, the script writes both RPP and LOF projects to files, using the working directory name and appropriate suffix.
`--rpp` and `--lof` can optionally be followed by a filename, which can be `-` for stdout.
If only one of the two is specified, the other is not written at all.
