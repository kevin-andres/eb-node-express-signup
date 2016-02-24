#!/bin/bash -e
# blame: barry@productops.com  Feb 2016
# you can run this -x to learn what it does under the hood

if [ `dirname $0` = . ] ; then
    EBCONFIG=".elasticbeanstalk/config.yml"
else
    EBCONFIG=`dirname $0`/".elasticbeanstalk/config.yml"
fi
ME=`basename $0`
EC2USER=ec2-user
AWSCONFIG=~/.aws/config

givehelp()
{
cat <<EOF

STANDARD VERBS:
	$ME env deploy           deploy to the given environment
	$ME env update           just update the artifact 
	$ME env ssh              ssh to the given box
	$ME env put here there   copy a file to /home/ec2-user/there
	$ME env get there here   copy a file from there to here
        $ME env open             open a browser on the box 
        $ME env use              use environment env (not necessary)
        $ME local run            run a local copy of the app
        
SPECIAL VERBS:
        $ME init                 initialize elastic beanstalk (after git clone)
        $ME init appname         initialize elastic beanstalk (after git clone)
        $ME list                 list available environments
        $ME myip                 find out what my (laptop) ip is

ELASTIC BEANSTALK VERBS:
        $ME env describe         describe the environment

        $ME env id               get instance id (of first instance)
        $ME env ipaddr           get instance ipaddress
        $ME env instance         describe the instance

        $ME env sgn              get security group id
        $ME env security         describe security group 

        $ME env cname            display the cname of the lb
        $ME env r53cname foo     wire up a route53 name 'foo'

        $ME env asg              get autoscaling group name
        $ME env asgdescribe      describe the autoscaling group
        $ME env scale min max    set asg min and max 
        $ME env cooldown n       cooldown in seconds between asg actions
        $ME env setitype type    set instance type, like t1.micro or m3.medium

TECH LEAD VERBS:
        $ME new                  create application based on this dir name
        $ME new appname          create application 'appname'
        $ME new appname args..   create application appname
        $ME createenv env        create environment 'env-appname'
        $ME createenv env [more args]
        $ME env limitip          limit ssh ip to my public ip
        $ME env limitip cidr     limit ssh ip e.g. 0.0.0.0/0
EOF
	exit 3
}

# ----------------------------------------------------------------------
# ----------------------------------------------------------------------
# ----------------------------------------------------------------------

# some helper methods/functions

# get a config value from a config file
cfgget() {
    # $1 = filename
    # $2 = section
    # $3 = item
    if ! python -c "import ConfigParser, os;" 2>/dev/null ; then
	pip install ConfigParser 2>/dev/null >/dev/null
    fi
    python -c "import ConfigParser, os ; config=ConfigParser.ConfigParser() ; config.readfp(open('"$1"')); print config.get('"$2"','"$3"')"
}

# does yaml to json on stdin
yaml2json() {
    # if we have y2j and yq from https://github.com/wildducktheories/y2j then use it because it's more robust
    if [ `which y2j` ] ; then 
	y2j
    elif python -c "import sys, yaml, json;" 2>/dev/null ; then
	python -c 'import sys, yaml, json; json.dump(yaml.load(sys.stdin), sys.stdout, indent=4)' 
    else
	echo "ERROR: your python is broken, and you don't have y2j installed" >&2
	echo "       https://github.com/wildducktheories/y2j " >&2
    fi
}

ebregion() {
    cat $EBCONFIG | yaml2json | jq .global.default_region | tr -d '"' 
}

awsregion() {
    if [ -f $AWSCONFIG ] ; then 
	# should be in the default section
	REGION=`cfgget $AWSCONFIG default region 2>/dev/null`
	if [ -z $REGION ] ; then
	    # maybe in the global section
	    REGION=`cfgget $AWSCONFIG global region 2>/dev/null`
	fi
	if [ -z $REGION ] ; then 
	    # some other section, then?
	    REGION=`cat $AWSCONFIG | grep ^region | head -1 | cut -f 2 -d =`
	fi
	if [ ! -z $REGION ] ; then 
	    echo $REGION 
	fi
    fi
}

setregion() {
    # get the region out of your aws config or eb config
    if [ -f $EBCONFIG ] ; then
    	REGION=`ebregion`
    fi
    if [ -f $AWSCONFIG ] && [ -z $REGION ] ; then 
	REGION=`awsregion`
    fi
    if [ -z $REGION ] ; then
	# pick a sensible default
	REGION=us-west-2
    fi
    echo $REGION
}

ebkeyname() {
    cat $EBCONFIG | yaml2json |  jq .global.default_ec2_keyname | tr -d '"' 
}

ebinstance() {
#        $ME env id               get instance id
    # INSTANCE=`eb list -v | grep $ENV | cut -d \' -f 2`
    if [ ! -z $1 ] ; then 
	ORDINAL=$1
    else
	ORDINAL=
    fi
    aws elasticbeanstalk describe-environment-resources  --environment-name $ENV | jq .EnvironmentResources.Instances[${ORDINAL}].Id | tr -d \" 
}

ebinstanceipaddr() {
#        $ME env ipaddr           get instance ipaddress
    INSTANCE=$1
    if [ ! -z $INSTANCE ] ; then
	aws ec2 describe-instances --instance-ids $INSTANCE | jq .Reservations[].Instances[].PublicIpAddress | tr -d \"
    fi
}

ebdefaultenv() {
    # stupid jq can't take names with a dash in them
    cat $EBCONFIG | sed -e s/branch-defaults/foo/ | y2j .foo.default.environment
}

whatsmyip() {
#        $ME myip                 find out what my (laptop) ip is
    curl -s http://www.whatsmyip.website/api/plaintext | head -1
}

ebsgn() {
#        $ME env sgn              get security group id
    ID=`ebinstance`
    aws ec2 describe-instances --instance-ids $ID | jq .Reservations[].Instances[].SecurityGroups[].GroupName | tr -d \" 
}

ebsgid() {
#        $ME env sgn              get security group id
    ID=`ebinstance`
    aws ec2 describe-instances --instance-ids $ID | jq .Reservations[].Instances[].SecurityGroups[].GroupName | tr -d \" 
}

ebcname() {
#        $ME env cname            display the cname of the lb
    aws elasticbeanstalk describe-environments --environment-names $ENV | jq .Environments[].CNAME | tr -d \"
}

route53wire() {
# something like 
#    route53wire `ebcname` foo.example.com
TONAME=$1
R53NAME=$2
# assume it's three-part, not four
R53DOMAIN=`echo $R53NAME | cut -f 2-3 -d .`
# now get the zone id
ZID=`aws route53 list-hosted-zones-by-name --dns-name $R53DOMAIN | jq .HostedZones[].Id | tr -d \" | cut -d / -f 3`
if [ -z $ZID ] ; then
    echo "ERROR $R53DOMAIN is not hosted in aws route53"
    exit 5
fi

# create a resource record to update this guy
RESREC=/tmp/route53.$$.json
cat >$RESREC <<EOF
{
  "Comment": "$0 for AWS EB by '$USER' on '$HOSTNAME' in '$PWD'", 
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$R53NAME",
        "Type": "CNAME",
        "ResourceRecords": [
          {
            "Value": "$TONAME"
          }
        ],
        "TTL": 300
      }
    }
  ]
}
EOF

# now actually write the record
aws route53 change-resource-record-sets --hosted-zone-id $ZID --change-batch file://$RESREC
rm $RESREC
}

route53cname() {
#        $ME env r53cname foo     wire up a route53 name 'foo'
	if [ ! -z $1 ] ; then 
	    route53wire `ebcname` $1
	else
	    echo "ERROR: no target name to wire up" >&2
	fi
}

asgname() {
#        $ME env asg              get autoscaling group name
    ID=`ebinstance`
    aws ec2 describe-instances --instance-ids $ID  | jq .Reservations[].Instances[].Tags[].Value | tr -d \" | grep -v ^AWSEBAutoScalingGroup | grep AWSEBAutoScalingGroup | tail -1
}

asgdescribe() {
#        $ME env asgdescribe      describe the autoscaling group
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names `asgname`
}

appname() {
    cat $EBCONFIG | yaml2json | jq .global.application_name | tr -d \"  
}

# create an ed script for editing a configuration as produced by `eb config`
# and then execute it with
#     export EDITOR="cat $FILE | ed" ; eb config
ebeditconfig() {
    EFILE=/tmp/ebconfig.hack.$$
    if [  -f $EFILE ] ; then rm -rf $EFILE ; fi

    while [ ! -z $3 ] 
    do
	SECTION=$1
	KEY=$2
	VAL=$3
# find the section
# delete the key
# go back to the top of the section
# insert the new key right after the section header
cat >>$EFILE <<EOF
/  $SECTION/
/$KEY:/d
/  $SECTION/
a
    $KEY: $VAL
.

EOF
shift ; shift ; shift 
done
cat >>$EFILE <<EOF
w
q

EOF
    export EDITOR="cat $EFILE | ed >/dev/null "
    eb config && rm $EFILE
}

eblistapps() {
    aws elasticbeanstalk describe-applications | jq .Applications[].ApplicationName
}

eblimitip() {
#        $ME env limitip          limit ssh ip to my public ip	
	if [ -z $1 ] ; then
	    CIDR=`whatsmyip`/32
	else
	    CIDR=$1
	    if ! echo $CIDR | grep / >/dev/null ; then
		echo "ERROR: $CIDR is not in CIDR a.b.c.d/m form" >&2
		exit 73
	    fi
	fi
	echo  INFO: About To Set SSHSourceRestriction: tcp,22,22,$CIDR
	ebeditconfig aws:autoscaling:launchconfiguration: SSHSourceRestriction tcp,22,22,$CIDR
}

ebsetitype() {
#        $ME env setitype type    set instance type, like t1.micro or m3.medium
	if [ -z $1 ] ; then 
	    echo " --- current value ---"
	else
	    # if MinInstancesInService is set to 0 you may get a service outage
	    MAXSIZE=`asgdescribe | jq .AutoScalingGroups[].MaxSize`
	    MINSIZE=`asgdescribe | jq .AutoScalingGroups[].MaxSize`
	    MAXBATCH="aws:autoscaling:updatepolicy:rollingupdate: MaxBatchSize '1'"
	    MININSTANCES="aws:autoscaling:updatepolicy:rollingupdate: MinInstancesInService '$MINSIZE'"
	    ROLLUPTRUE="aws:autoscaling:updatepolicy:rollingupdate: RollingUpdateEnabled 'true'"
	    if [ $MAXSIZE -eq 1 ] || [ $MAXSIZE -eq $MINSIZE ] ; then
		NEWMAX=$[ $MAXSIZE + 1 ]
		echo "INFO: Auto Scaling Group MaxSize Increased To $NEWMAX"
		BUMPMAX="aws:autoscaling:asg: MaxSize '$NEWMAX'"
	    fi	    
	    # if youhavebeenwarned ; then 
		if ! ebeditconfig $MAXBATCH $MININSTANCES $BUMPMAX  $ROLLUPTRUE aws:autoscaling:launchconfiguration: InstanceType $1
		then 
		    echo "If you failed due to the dreaded VPC problem, read"
		    echo '  https://mike-thomson.com/blog/?p=2103#more-2103'
		fi
            # fi
	    asgdescribe | egrep 'Size|Desired|MinInstancesInService|RollingUpdate|MaxBatchSize'
	fi
	aws ec2 describe-instances --instance-ids `ebinstance` | grep InstanceType
}

ebsetcount() {
#        $ME env count n          set asg max and min to n
	if [ -z $1 ] ; then 
	    echo " --- current values ---"
	else    
	    # we could probably the scale code above, just with MIN = MAX
	    # BUT 'eb scale' sets AutoScalingGroups[].DesiredCapacity which is NOT in the config
	    eb scale $1
	fi
	asgdescribe | egrep 'Size|Desired'
}

ebsetcooldown() {
#        $ME env cooldown n       cooldown in seconds between asg actions
	if [ -z $1 ] ; then 
	    echo " --- current values ---"
	else    
	    # aws autoscaling update-auto-scaling-group --auto-scaling-group-name `asgname` --default-cooldown $1
	    ebeditconfig aws:autoscaling:asg: Cooldown $1
	fi
	asgdescribe | grep Cooldown
}

ebsetscale() {
#        $ME env scale min max    set asg min and max 
	if [ -z $1 ] || [ -z $2 ] ; then
	    echo " --- current values ---"
	    asgdescribe | egrep 'Size|Desired'
	else
	    if [ $1 -lt $2 ] ; then
		MINV=$1
		MAXV=$2
	    else
	        # swap the args if we need to
		MINV=$2
		MAXV=$1
	    fi
	    # set the MinInstancesInService to something sensible, based on max
	    MAXBATCH="aws:autoscaling:updatepolicy:rollingupdate: MaxBatchSize '1'"
	    MIN="aws:autoscaling:asg: MinSize '$MINV'"
	    MAX="aws:autoscaling:asg: MaxSize '$MAXV'"
	    ROLLUPTRUE="aws:autoscaling:updatepolicy:rollingupdate: RollingUpdateEnabled 'true'"
	    if [ $MAXV -eq 1 ] ; then 
		MININSTANCES="aws:autoscaling:updatepolicy:rollingupdate: MinInstancesInService '0'"
	    elif [ $MAXV -gt $MINV ] ; then 
		MININSTANCES="aws:autoscaling:updatepolicy:rollingupdate: MinInstancesInService '$MINV'"
	    else 
		MININSTANCES="aws:autoscaling:updatepolicy:rollingupdate: MinInstancesInService '1'"	    
	    fi
	    ebeditconfig $MIN $MAX $MAXBATCH $MININSTANCES $ROLLUPTRUE
	    asgdescribe | egrep 'Size|Desired|MinInstancesInService|RollingUpdate|MaxBatchSize'
	fi
}

ebnew() {
#        $ME new                  create application based on this dir name
#        $ME new appname          create application appname
	    if [ -z $2 ] ; then
		APPNAME=`basename $PWD`
		shift
	    else
		APPNAME=$2
		shift ; shift
	    fi
	    if [ $# -eq 0 ] ; then # no other args
		if ! eblistapps | grep '"'$APPNAME'"' >/dev/null; then
		    eb init $APPNAME -p PHP --region $REGION 
		else
		    echo "ERROR: appname $APPNAME already exists" >&2
		    echo "     maybe you want to pick a different name (not in the list below)" >&2
		    eblistapps 
		fi
	    else
#        $ME new appname args..     create application appname
		    # if they gave us a bunch of args, just pass them all thru as if they know what they're doing
                 eb init $APPNAME $*
	     fi
}

ebinit() {
#        $ME init                 initialize elastic beanstalk (after git clone)
#        $ME init appname         initialize elastic beanstalk (after git clone)
	    if [ -z $2 ] ; then
		APPNAME=`basename $PWD`
	    else
		APPNAME=$2
	    fi
	    # this is for use by regular developers
	     if  eblistapps | grep '"'$APPNAME'"' >/dev/null; then
		 eb init $APPNAME --region $REGION		    
	     else
		 echo "ERROR: appname $APPNAME does not exist" >&2
		 echo "   maybe you meant to use one of these:" >&2
		 eblistapps 
	     fi
}

ebcreate() {
#        $ME create env           create environment 'env-appname'
	    shift
	    if [ -z $1 ] ; then 
		echo "ERROR: you must specify an environment name prefix like 'test' or 'prod'" >&2
		exit
	    fi
	    ENVNAME=${1}-` appname `
	    if [ $ENVNAME = ${1}- ] ; then 
		ENVNAME=${1}-`basename $PWD`
	    fi
	    echo " BE PATIENT: THIS MAY TAKE A WHILE AND WILL DEPLOY AT LEAST ONE INSTANCE ALONG THE WAY "
	    shift 
	    eb create $ENVNAME $*
}

ebputget() {
#	$ME env put here there   copy a file to /home/ec2-user/there
#	$ME env get there here   copy a file from there to here
	if [ -z $1 ] || [ -z $2 ] ; then
	    echo "ERROR - no files to $ACTION" >&2
	    givehelp
	    exit 53
        else
	    INSTANCE=` ebinstance `
	    IPADDR=` ebinstanceipaddr $INSTANCE `
	    # do this to open port 22
	    cat /dev/null | eb ssh -o
	    if [ $ACTION = put ] ; then 
		scp $* ${EC2USER}@${IPADDR}:/home/$EC2USER
	    elif [ $ACTION = get ] ; then
		scp ${EC2USER}@${IPADDR}:/home/$EC2USER/"$1" "$2"
	    else
		# unreachable
		echo "ERROR: don't know how to $ME $ENV $ACTION" >&2
		exit 59
	    fi
	    # do this to close port 22
	    cat /dev/null | eb ssh 
	fi
}

youhavebeenwarned() {
    echo "WARNING: THIS MAY KILL ALL THE INSTANCES IN YOUR ENVIRONMENT"
    echo "  you can avoid a service outage by:" 
    echo "    - create a new environment"
    echo "    - change the instance type there"
    echo "    - use 'eb swap' to interchange the environments"
    echo "    - delete the extra environment"
    echo -n "ARE YOU ABSOLUTELY SURE YOU WANT TO PROCEED? "
    read ANSWER
    if [ $ANSWER = y ] || [ $ANSWER = yes ] ||  [ $ANSWER = Y ] || [ $ANSWER = Yes ] ; then 
	echo " --- YOU HAVE BEEN WARNED! ---"
	true
    else 
	false
    fi
}


# ----------------------------------------------------------------------
# ----------------------------------------------------------------------
# ----------------------------------------------------------------------

# detect no args at all
if [ -z $1 ] ; then
    givehelp
    exit 7
else
    # check to see if we've run `eb init` yet
    if [ $1 != init ] || [ $1 != new ] ; then 
	if [ ! -f $EBCONFIG ] ; then
	    echo "ERROR: you must run '$ME init' first before anything else" >&2
	    echo " " >&2
	    givehelp
	    exit 11
	fi
    fi

    REGION=`setregion`

# ----------------------------------------------------------------------
# ----------------------------------------------------------------------
# ----------------------------------------------------------------------

# Process the 'no env' verbs
    case $1 in
    # first arg is usually the Environment, 
    # but sometiemes it's a verb
	new)
#        $ME new                  create application based on this dir name
#        $ME new appname          create application appname
#        $ME new appname args..     create application appname
	     ebnew $*
	     exit
	     ;;
	 init)
#        $ME init                 initialize elastic beanstalk (after git clone)
#        $ME init appname         initialize elastic beanstalk (after git clone)
	     ebinit $*
	     exit
	     ;;
	create|createenv)
#        $ME create env           create environment 'env-appname'
	    ebcreate $*
	    exit 
	    ;;
	list)
#        $ME list                 list available environments
	    eb list
	    exit 
	    ;;
	local)
#        $ME local run            run a local copy of the app
	    # could probably vagrant or docker to do this, but not today
	    echo "ERROR: '$ME local $2' is not supported" >&2
	    givehelp
	    exit 
	    ;;
	myip)
#        $ME myip                 find out what my (laptop) ip is
	    whatsmyip
	    exit 
	    ;;
    esac
fi

# ----------------------------------------------------------------------
# detect bad environment name by trying to switch to it

# first arg is usually the Environment
# try several likely combinations
ENV1=$1
ENV2=${1}-` appname `
ENV3=${1}-`basename $PWD`
if  eb use $ENV1 1>/dev/null 2>/dev/null; then
    ENV=$ENV1
elif eb use $ENV2 1>/dev/null 2>/dev/null ; then
    ENV=$ENV2
elif eb use $ENV3 1>/dev/null 2>/dev/null ; then
    ENV=$ENV3
else 
cat >&2 <<EOF    
ERROR: cannot find a working environment
ERROR: environment '$ENV1' does not exist
ERROR: environment '$ENV2' does not exist
ERROR: environment '$ENV3' does not exist
  maybe you want one of these:
EOF
eb list
exit 41
fi

if [ -z $2 ] ; then
    givehelp
    exit 43
else
    ACTION=$2
    shift; shift
fi



# ----------------------------------------------------------------------
# ----------------------------------------------------------------------
# ----------------------------------------------------------------------

# Process all other verbs
# now parse the 'action' keyword
case $ACTION in
    use)
#        $ME env use              use environment env (not necessary)
	;;

    update|deploy)
#	$ME env deploy           deploy to the given environment
#	$ME env update           just update the artifact 
	eb deploy 
	;;
    ssh)
#	$ME env ssh              ssh to the given box
	eb ssh
	;;
    put|get)
#	$ME env put here there   copy a file to /home/ec2-user/there
#	$ME env get there here   copy a file from there to here
	ebputget $*
	;;
    open)
#        $ME env open             open a browser on the box 
	eb open
	;;
    id)
#        $ME env id               get instance id
	ebinstance
	;;
    ipaddr)
#        $ME env ipaddr           get instance ipaddress
	ebinstanceipaddr `ebinstance`
	;;
    instance)
#        $ME env instance         describe the instance
	aws ec2 describe-instances --instance-ids `ebinstance`
	;;
    sgn)
#        $ME env sgn              get security group id
	ebsgn
	;;
    security)
#        $ME env security         describe security group 
	aws ec2 describe-security-groups --group-names `ebsgn`
	;;
    cname)
#        $ME env cname            display the cname of the lb
	ebcname
	;;
    describe)
#        $ME env describe         describe the environment
	aws elasticbeanstalk describe-environments --environment-names $ENV 
	;;
    r53cname|route53cname)
#        $ME env r53cname foo     wire up a route53 name 'foo'
	route53cname $1
	;;
    scale)
#        $ME env scale min max    set asg min and max 
	ebsetscale $1 $2
	;;
    cooldown)
#        $ME env cooldown n       cooldown in seconds between asg actions
	ebsetcooldown $1
	;;
    count)
#        $ME env count n          set asg max and min to n
	ebsetcount $1
	;;
    setitype)
#        $ME env setitype type    set instance type, like t1.micro or m3.medium
	ebsetitype $1
	;;
    asg)
#        $ME env asg              get autoscaling group name
	asgname
	;;
    asgdescribe)
#        $ME env asgdescribe      describe the autoscaling group
	asgdescribe
	;;
    limitip)
#        $ME env limitip          limit ssh ip to my public ip	
	eblimitip $1
	;;
    *)
	givehelp
	;;
esac