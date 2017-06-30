#!/bin/bash

# Error codes
E_PARAMS=10
E_WGET=11
E_UPDATE=12

# Default parameters
admin='admin'
theme='default-bootstrap'

# Helper
function display_help {
  cat <<EOF
Usage:
  updatePrestashop -v <version> -d <directory> [-option <argument>]

Backups and updates Prestashop.

Commands:
  -v, --version    Prestashop version.
  -d, --directory  Prestashop directory path.
  -t, --theme      Theme directory name (default to "default-bootstrap").
  -a, --admin      Admin directory name (default to "admin").
EOF
}

# Parse and assign given parameters
while : ; do
  case $1 in
    -h|--help)
      display_help
      exit
      ;;
    -v|--version)
      version=$2
      shift 2
      ;;
    -d|--directory)
      dir=${2%/}
      shift 2
      ;;
    -t|--theme)
      theme=$2
      shift 2
      ;;
    -a|--admin)
      admin=$2
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown option \"$1\"" >&2
      exit $E_PARAMS
      ;;
    *)
      break
      ;;
  esac
done

# Check given parameters.
if [[ -z $version || -z $dir ]]; then
  echo 'Error: missing parameter (update-prestashop -h to display help).' >&2
  exit $E_PARAMS
elif [[ ! -d $dir ]]; then
  echo "Error: $dir does not exist or is not a directory." >&2
  exit $E_PARAMS
fi

# Files to copy without overriding
copy=(download/* img/* modules/* override/* pdf/* themes/"$theme" upload/*)

# Files to copy by overriding
copy_over=(.htaccess *.xml config/defines_custom.inc.php config/settings.inc.php \
img/favicon.ico img/logo.jpg img/logo_invoice.jpg img/logo_stores.png \
mails/* translations/*)

# Files to remove
delete=(architecture.md docs CONTRIBUT* README.md)

# Define shortcuts
url="https://download.prestashop.com/download/old/prestashop_$version.zip"
dir_owner=`stat -c '%U' "$dir"`
dir_tmp=`dirname "$dir"`/.tmp
zip="$dir_tmp"/`basename "$url"`
date=`date +'%Y%m%d'`

# Download and unzip prestashop
echo 'Downloading Prestashop...'
rm -rf "$dir_tmp"/prestashop $zip
mkdir -p "$dir_tmp"
wget -q -P "$dir_tmp" $url
if [[ $? -gt 0 ]]; then
  echo "Error: could not download Prestashop $version." >&2
  exit $E_WGET
fi
echo 'Unzipping files...'
unzip -qq $zip -d "$dir_tmp"
rm -f $zip "$dir_tmp"/*.html

# Copy files.
echo 'Copying files...'
for file in "${copy[@]}"
do
  cp -Rn "$dir"/$file "$dir_tmp"/prestashop/`dirname $file`
done
for file in "${copy_over[@]}"
do
  # `/bin/cp` prevents any alias to `cp -i` (interactive mode)
  /bin/cp -R "$dir"/$file "$dir_tmp"/prestashop/`dirname $file`
done
for file in "${delete[@]}"
do
  rm -rf "$dir_tmp"/prestashop/$file
done

# Rename admin folder
[[ ! -z $admin ]] && mv "$dir_tmp"/prestashop/admin "$dir_tmp"/prestashop/"$admin"

# Ask user to set maintenance mode.
echo -n 'Please set your shop to maintenance mode and confirm to continue (y/n) '
read confirmed
if [[ ! $confirmed =~ ^(y|Y).*$ ]]; then
  echo 'Operation aborted.'
  exit
fi

# Backup database and files.
echo 'Backing up database...'
function backup_database {
  echo -n 'Enter database name: '
  read db_name
  echo -n 'Enter database username: '
  read db_user
  echo 'Enter database password: '
  read -s db_passwd
  mysqldump -u "$db_user" --password="$db_passwd" "$db_name" > "$dir_tmp"/backup$date.sql
  if [[ $? -gt 0 ]]; then
    echo -n 'Error: could not connect to database or database name does not exist. Try again? (y/n) '
    read retry
    if [[ $retry =~ ^(y|Y).*$ ]]; then
      backup_database
    else
      echo 'Operation aborted.'
      exit
    fi
  fi
}
backup_database
echo 'Backing up files...'
tar -zcpf "$dir_tmp"/backup"$date".tar.gz -C `dirname "$dir"` `basename "$dir"`
echo "Replacing old with new files..."
find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} \;
find "$dir_tmp"/prestashop -mindepth 1 -maxdepth 1 -exec mv {}  "$dir" \;
rmdir "$dir_tmp"/prestashop
chown -R $dir_owner:$dir_owner "$dir"

# Validate update
# Edit install/upgrade/upgrade.php and comment lines 206 to 210
# http://forge.prestashop.com/browse/PSCSX-8524?focusedCommentId=135608
sed -i '206c /*' "$dir"/install/upgrade/upgrade.php
sed -i '210c */' "$dir"/install/upgrade/upgrade.php
echo -n 'Please type in the url of your shop: '
read shop_url
function validate_update {
  # upgrade.php overrides `settings.inc.php`
  mv "$dir"/config/settings.inc.php "$dir"/config/tmp.settings.inc.php
  local xml=`curl -sk "$shop_url"/install/upgrade/upgrade.php`
  if [[ $? -gt 0 ]]; then
    echo -n 'Error: could not request your shop URL. Try again? (y/n).'
    read retry
    if [[ $retry =~ ^(y|Y).*$ ]]; then
      validate_update
    else
      echo 'Operation aborted.'
      exit
    fi
  fi
  echo `grep -oPm1 "(?<=<result>)[^<]+" <<< $xml`
}
if [[ `validate_update` != 'ok' ]]; then
  mv -f "$dir"/config/tmp.settings.inc.php "$dir"/config/settings.inc.php
  echo 'Error: failed to update your shop.' >&2
  echo -e "Error: visit $shop_url/install/upgrade/upgrade.php to get more details." >&2
  exit $E_UPDATE
else
  echo 'Your shop has been successfully updated. Maintenance mode can be disabled.'
  mv -f "$dir"/config/tmp.settings.inc.php "$dir"/config/settings.inc.php
  rm -rf $dir/install
  exit
fi
