#!/bin/bash -e

#    publish-recordings.sh Prepare and upload recordings off-site
#    Copyright (C) 2020 Peter L Jones <peter@drealm.info>
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
#    See LICENCE.txt for the full text.
#


# Modifications 2020-2021 by Kevin Doren for upload to AWS S3 bucket.
#
# prerequisites:
#
# 1) Create an S3 bucket for recordings
#    Use this guide to make it browsable:  https://github.com/rufuspollock/s3-bucket-listing
#
#    create a deletion policy under "Management" -> "Lifecycle Rules"
# 
# 2) Create an AWS user with appropriate permissions (access to the required S3 bucket)
#    in AWS IAM, create a user (i.e jamulus-server)
#    "Permissions": add desired permissions to this user
#        Quick but less secure way: attach polich "AmazonS3FullAccess
#        Secure way: Create and attach a policy granting access only to 1 bucket.
#    "Security Credentials": "Create access key" and save the key
#
# 3) install required packages:
#    apt-get install awscli jq ffmpeg zip
#
# 4) configure awscli with your key and region:
#
#      cat <<EOF > /root/.aws/credentials
#      [default]
#      aws_access_key_id = <AWS_ACCESS_KEY_ID>
#      aws_secret_access_key = <AWS_SECRET_ACCESS_KEY>
#      EOF
#
#      mkdir /root/.aws
#      cat <<EOF > /root/.aws/config
#      [default]
#      region=us-west-2
#      output=json
#      EOF
#
# 5) test:  aws s3 ls: s3://<s3-bucket-name>

#
# Set some default parameter values (except for S3 bucket name which has no default)
# Params can be set either from command line, or in file /etc/publish-recording.conf
#

# Name of S3 bucket, and prefix to use when writing objects:
#
# There is no default value for S3_BUCKET,
# it must be specified on command line with --bucket argument
# or in config file /etc/publish-recordings.conf
#
# S3_BUCKET=<name of S3 bucket>
PREFIX=jamulus

# if not using S3, scp may be used.  This requires a key file with proper permissions, and a destination host including username:
# SSH_KEY=/root/.ssh/user-private-key.pem
# RECORDING_HOST_DIR=user@hostname:/home/user/recordings/

# Recording directory used by Jamulus server:
# Example: command line argument to Jamulus server:
#   --recording /var/recordings/
#
RECORDING_DIR=/var/recordings

# File used by Jamulus server to report html status, and idle message:
# Example: command line argument to Jamulus server:
#   --htmlstatus /tmp/jamulus-server-status.html
#
JAMULUS_STATUSPAGE=/tmp/jamulus-server-status.html
NO_CLIENT_CONNECTED="No client connected"

# optional zip archive password
# ZIP_PASSWORD=secret_password

if [ -f /etc/publish-recordings.conf ]; then
	source /etc/publish-recordings.conf
fi

#
# This script can be invoked periodically by a crontab entry.
# In that case, you don't need inotify-publisher.sh or inotify-publisher.service.
#
# If any client is connected, this script will return without doing anything
#
# crontab entry can be as follows:
#
# 0,30 * * * * export HOME=/root; /bin/bash /usr/local/bin/publish-recordings.sh >> /var/log/publish-recordings.log 2>&1
#
if ! grep -q "${NO_CLIENT_CONNECTED}" "${JAMULUS_STATUSPAGE}"; then
	echo "`date`: publish_recordings.sh: exiting due to clients connected"
	exit 0  # exit if server has clients connected
fi

while [ $# != 0 ] ; do
  case $1 in
    --bucket | -b )
      S3_BUCKET="$2"
      shift 2
      ;;
    --recording | -R )
      RECORDING_DIR="$2"
      shift 2
      ;;
    --prefix | -p )
      PREFIX="$2"
      shift 2
      ;;
    --htmlstatus | -m )
      JAMULUS_STATUSPAGE="$2"
      shift 2
      ;;
    * )
      echo error: unknown argument $1
      exit 1
      ;;
  esac
done

[[ -z "$S3_BUCKET" ]] && echo "Error: no --bucket specified" && exit 1


echo "`date`: publish_recordings.sh: no clients connected, checking for recordings"

cd "${RECORDING_DIR}"

find -maxdepth 1 -type d -name 'Jam-*' | sort | \
while read jamDir
do
	rppFile="${jamDir#./}.rpp"
	[[ -f "${jamDir}/${rppFile}" ]] || continue
	(
		cd "$jamDir"

		find -maxdepth 1 -type f -name '*.wav' | sort | while read wavFile
		do
			lra=0
			integrated=0
			removeWaveFromRpp=false

			duration=$(nice -n 19 ffprobe -v 0 -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$wavFile")
			if [[ ${duration%.*} -lt 60 ]]
			then
				removeWaveFromRpp=true
				echo -n ''
			else
				opusFile="${wavFile%.wav}.opus"
				declare -a stats=($(
					nice -n 19 ffmpeg -y -hide_banner -nostats -nostdin -i "${wavFile}" -af ebur128 -b:a 192k "${opusFile}" 2>&1 | \
						grep '^ *\(I:\|LRA:\)' | { read x y x; read x z x; echo $y $z; }
				))
[[ ${#stats[@]} -eq 2 ]]
				integrated=${stats[0]}
				lra=${stats[1]}
				echo "$duration $lra $integrated" | awk '{ if ( $1 >= 60 && ( $2 > 6 || $3 > -48 ) ) exit 0; exit 1 }' || {
					rm "${opusFile}"
					removeWaveFromRpp=true
				}
			fi

			if $removeWaveFromRpp
			then
				echo "Removed ${wavFile} - duration $duration, lra $lra, integrated $integrated"
				# Magic sed command to remove an item from a track with a particular source wave file
				sed -e '/^    <ITEM */{N;N;N;N;N;N;N;N;N;N;N;N}' \
					-e "\%^ *<SOURCE WAVE\n *FILE *[^>]*${wavFile}\"\n *>\n%Md" \
					"${rppFile}" > "${rppFile}.tmp" && \
					mv "${rppFile}.tmp" "${rppFile}"
			else
				echo "Kept ${opusFile} - duration $duration, lra $lra, integrated $integrated"
			fi

			rm "$wavFile"
		done

		# Magic sed command to remove empty tracks
		sed -e '/^  <TRACK {/{N;N;N}' -e '/^ *<TRACK\([^>]\|\n\)*>$/d' \
			"${rppFile}" > "${rppFile}.tmp" && \
			mv "${rppFile}.tmp" "${rppFile}"

		if grep -q 'ITEM' "${rppFile}"
		then
			# Replace any remaining references to WAV files with OPUS compressed versions
			sed -e 's/\.wav/.opus/' -e 's/WAVE/OPUS/' \
				"${rppFile}" > "${rppFile}.tmp" && \
				mv "${rppFile}.tmp" "${rppFile}"
			# Note, Audacity won't like the OPUS files...
		else
			# As no items were left, remove the project
			echo `date`: Removing ${rppFile}
			rm "${rppFile}"
			echo `date`: Removing ${rppFile/rpp/lof}
			rm "${rppFile/rpp/lof}"
		fi

	)
	if [[ "$(cd "${jamDir}"; echo *)" == "*" ]]
	then
		echo `date`: Removing dir ${jamDir}
		rmdir "${jamDir}"
	else
		ARCHIVE="${jamDir}.zip"
		echo `date`: Zipping dir ${jamDir} to $ARCHIVE
		if [ -n "$ZIP_PASSWORD" ]; then
			ZIP_COMMAND="nice -n 19 zip -P${ZIP_PASSWORD} -rj $ARCHIVE ${jamDir} -i '*.opus' '*.rpp'"
		else
			ZIP_COMMAND="nice -n 19 zip -rj $ARCHIVE ${jamDir} -i '*.opus' '*.rpp'"
		fi
		eval $ZIP_COMMAND && {
			rm -r "${jamDir}"
		        echo `date`: Copying ${jamDir}.zip to target
			i=10
			if [ -n "$S3_BUCKET" ]; then
				while [[ $i -gt 0 ]] && ! nice -n 19 aws s3 cp "$ARCHIVE" s3://$S3_BUCKET/$PREFIX/ --acl public-read
				do
					(( i-- ))
					sleep $(( 11 - i ))
				done
			elif [ -n "$RECORDING_HOST_DIR" ]; then
				while [[ $i -gt 0 ]] && ! scp -i ${SSH_KEY} -o ConnectionAttempts=6 "${jamDir}.zip" ${RECORDING_HOST_DIR}
				do
					(( i-- ))
					sleep $(( 11 - i ))
				done
			fi
			[[ $i -gt 0 ]]
			echo `date`: Removing $ARCHIVE
			rm "$ARCHIVE"
		}
	fi
done
