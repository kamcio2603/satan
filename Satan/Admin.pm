#!/usr/bin/perl
#
# Satan::Admin
# Rootnode http://rootnode.net
#
# Copyright (C) 2009-2012 Marcin Hlybin
# All rights reserved.
#
package Satan::Admin;

use Satan::Tools;
use Rootnode::Validate;
use DBI;
use Data::Dumper;
use Smart::Comments;
use Crypt::GeneratePassword qw(chars);
use Data::Password qw(:all);
use Crypt::PasswdMD5 ;
use FindBin qw($Bin);
use Readonly;
use feature 'switch';
use utf8;
use warnings;
use strict;

$|++;
$SIG{CHLD} = 'IGNORE';

# Data::Password variables
$MINLEN = 8;
$MAXLEN = 20;

Readonly my $MIN_UID => 2000;
Readonly my $MAX_UUD => 6500;

sub new {
	my ($class, $self) = @_;
	my $db;

	# Satan database
	my $satan = \%{ $db->{satan} };
	$satan->{dbh} = DBI->connect("dbi:mysql:satan;mysql_read_default_file=$Bin/../config/my.cnf",undef,undef,{ RaiseError => 1, AutoCommit => 0 });
	$satan->{add_user}      = $satan->{dbh}->prepare("INSERT INTO user_auth(uid, user_name, auth_key) VALUES (?, ?, PASSWORD(?))");
	$satan->{del_user}      = $satan->{dbh}->prepare("DELETE FROM user_auth WHERE user_name=?");
	$satan->{check_user}    = $satan->{dbh}->prepare("SELECT uid, user_name FROM user_auth WHERE uid=? OR user_name=?");
	$satan->{change_passwd} = $satan->{dbh}->prepare("UPDATE user_auth SET auth_key=PASSWORD(?) WHERE user_name=?");

	# PAM database
	my $pam = \%{ $db->{pam} };
	$pam->{dbh} = DBI->connect("dbi:mysql:nss;mysql_read_default_file=$Bin/../config/my.pam.cnf",undef,undef,{ RaiseError => 1, AutoCommit => 0 });

	# add
	$pam->{add_user}       = $pam->{dbh}->prepare("INSERT INTO all_users(uid, gid, user_name, realname, password, status, homedir, lastchange, min, max, owner) VALUES(?, ?, ?, ?, ?, 'A', ?, 0, $MINLEN, $MAXLEN, ?)"); 
	$pam->{add_group}      = $pam->{dbh}->prepare("REPLACE INTO all_groups(gid, group_name, owner)       VALUES (?, ?, ?)"); 
	$pam->{add_user_group} = $pam->{dbh}->prepare("REPLACE INTO all_user_group(user_id, group_id, owner) VALUES (?, ?, ?)");
	
	# delete
	$pam->{del_user}       = $pam->{dbh}->prepare("DELETE FROM all_users      WHERE owner=?");
	$pam->{del_group}      = $pam->{dbh}->prepare("DELETE FROM all_groups     WHERE owner=?");
	$pam->{del_user_group} = $pam->{dbh}->prepare("DELETE FROM all_user_group WHERE owner=?");

	# other
	$pam->{check_user}     = $pam->{dbh}->prepare("SELECT owner, user_name FROM all_users WHERE owner=? OR user_name=?"); 
	$pam->{change_passwd}  = $pam->{dbh}->prepare("UPDATE all_users SET password=? WHERE user_name=?");

	# grant
	$pam->{grant_passwd_user}       = $pam->{dbh}->prepare("GRANT SELECT(user_name,user_id,uid,gid,realname,shell,homedir,status) ON user       TO ? IDENTIFIED BY ?");
	$pam->{grant_passwd_group}      = $pam->{dbh}->prepare("GRANT SELECT(group_name,group_id,gid,group_password,status)           ON groups     TO ? IDENTIFIED BY ?");
	$pam->{grant_passwd_user_group} = $pam->{dbh}->prepare("GRANT SELECT(user_id,group_id)                                        ON user_group TO ? IDENTIFIED BY ?");

	$pam->{grant_shadow_user}       = $pam->{dbh}->prepare("GRANT SELECT(user_name,password,uid,gid,realname,shell,homedir,status,lastchange,min,max,warn,inact,expire) ON user TO ? IDENTIFIED BY ?");
	$pam->{grant_shadow_group}      = $pam->{dbh}->prepare("GRANT UPDATE(user_name,password,uid,gid,realname,shell,homedir,status,lastchange,min,max,warn,inact,expire) ON user TO ? IDENTIFIED BY ?");
	$pam->{drop_user}               = $pam->{dbh}->prepare("DROP USER ?");

	$self->{db} = $db;
	bless $self, $class;
	return $self;
}

sub DESTROY {
	my ($self) = @_;
	my $db = $self->{db};
	$db->{satan}->{dbh}->disconnect;
	$db->{pam}->{dbh}->disconnect;
	return;
}

sub crypt_password {
	my ($password) = @_;
	my @chars = ("A" .. "Z", "a" .. "z", 0 .. 9, qw(. /) );
	my $salt = join("", @chars[ map { rand @chars} ( 1 .. 8) ]);
	return unix_md5_crypt($password, $salt);
}

sub commit {
	my ($db) = @_;
	$db->{satan}->{dbh}->commit;
	$db->{pam}->{dbh}->commit;
	return;
}

sub adduser {
	my($self, @args) = @_;
	my $db = $self->{db};
		
	# SYNTAX
	# satan admin adduser <user_name> [uid <uid>] [ user_password <password> ] [ satan_key <key> ] [ mail yes|no ]

	# get username
	my $user_name = shift @args or return "Username not specified. Cannot proceed.";
	   $user_name = lc $user_name;
	
	# validate username
	my $bad_username = validate_username($user_name);
	   $bad_username and return "Wrong username. $bad_username.";
	
	# check if arguments are in key-value format
	if (@args % 2) {
		return "Uneven number of arguments. Only key-value accepted.";
	}

	# store key-value arguments as hash
	my %value_of = @args;

	# get uid 
	my $uid = $value_of{uid};
	if(not defined $uid) {
		## generating uid
		$uid = Satan::Tools->id(
			dbh    => $db->{satan}->{dbh}, 
			column => 'uid',
			table  => 'user_auth',
			min    => $MIN_UID
		);
	}

	### UID: $uid	

	# validate uid
	my $bad_uid = validate_uid($uid);
	   $bad_uid and return "Wrong uid. $bad_uid.";
	
	# get passwords or generate
	my $user_password = $value_of{user_password} || chars($MINLEN, $MAXLEN);
	my $satan_key     = $value_of{satan_key}     || chars($MINLEN, $MAXLEN);

	# crypt user password
	my $user_password_crypt = crypt_password($user_password);

	# check complexity of passwords
	my $bad_user_password = IsBadPassword($user_password);
	   $bad_user_password and return "User password is too simple: $bad_user_password.";	

	my $bad_satan_key = IsBadPassword($satan_key);
	   $bad_user_password and return "Satan password is too simple: $bad_satan_key.";

	# pam passwords
	my $pam_passwd = chars($MINLEN, $MAXLEN);
	my $pam_shadow = chars($MINLEN, $MAXLEN);

	# check user in db
	foreach my $type ( qw(pam satan) ) {
		$db->{$type}->{check_user}->execute($uid, $user_name) or return "Cannot check user $user_name ($uid). Database error: $@.";
		my ($db_uid, $db_user_name) = $db->{$type}->{check_user}->fetchrow_array;
		                              $db->{$type}->{check_user}->finish;

		if ($db->{$type}->{check_user}->rows) {
			return "User $user_name ($uid) already added to $type database: $db_user_name ($db_uid).";
		}
	}

	# add user
	eval {
		# satan user
		$db->{satan}->{add_user}->execute($uid, $user_name, $satan_key);

		# pam user
		## adduser
		$db->{pam}->{add_user}->execute($uid, $uid, $user_name, $user_name, $user_password_crypt, "/home/$user_name", $uid);
		my $user_id = $db->{pam}->{dbh}->{mysql_insertid};

		## group
		$db->{pam}->{add_group}->execute($uid, $user_name, $uid);
		my $group_id = $db->{pam}->{dbh}->{mysql_insertid};
		$db->{pam}->{add_user_group}->execute($user_id, $group_id, $uid);
		
		## grants
		$db->{pam}->{grant_passwd_user}->execute("$uid-passwd", $pam_passwd);
		$db->{pam}->{grant_passwd_group}->execute("$uid-passwd", $pam_passwd);
		$db->{pam}->{grant_passwd_user_group}->execute("$uid-passwd", $pam_passwd);
		$db->{pam}->{grant_shadow_user}->execute("$uid-shadow", $pam_shadow);
		$db->{pam}->{grant_shadow_group}->execute("$uid-shadow", $pam_shadow);
	} 
	or do {
		return "Cannot add user $user_name ($uid) to database. Database error: $@";
	};
	
	# prepare user data 
	$self->{data} = { 
		uid           => $uid,
		user_password => $user_password,
		satan_key     => $satan_key,
		pam_passwd    => $pam_passwd,
		pam_shadow    => $pam_shadow,
	};

	### Return data: $self->{data}

	commit($db);
	return;
}

sub deluser {
	my ($self, @args) = @_;
	my $db = $self->{db};

	# SYNTAX
	# satan admin deluser <user_name>

	# get username
	my $user_name = shift @args or return "Username not specified. Cannot proceed.";
	   $user_name = lc $user_name;

	# validate username
	my $bad_username = validate_username($user_name);
	   $bad_username and return "Wrong username. $bad_username.";
	
	# check if user exists
	my (%user_in);
	foreach my $type ( qw(satan pam) ) {
		$db->{$type}->{check_user}->execute(undef, $user_name) or return "Cannot check user $user_name. Database error: $@.";
		
		# store results in hash
		if ($db->{$type}->{check_user}->rows) {
			my ($db_uid, $db_user_name) = $db->{$type}->{check_user}->fetchrow_array;
			$user_in{$type} = $db_uid;
		}
		
		# finish statement
		$db->{$type}->{check_user}->finish;
	}

	### Users in DB: %user_in

	# interrupt if no user 
	if (!%user_in) {
		return "No such user $user_name in database.";
	} 

	# check if user is the same in both databases
	if (defined($user_in{satan} and $user_in{pam}) 
	        and $user_in{satan} !=  $user_in{pam}) {
		return "User exists but different uid in both databases (satan: $user_in{satan}, pam: $user_in{pam}.";
	}	

	# get uid
	my $uid = $user_in{satan} || $user_in{pam};

	# delete user
	eval {
		# user in satan database
		if (defined $user_in{satan}) {
			### Doing satan db statements
			### $user_name
			$db->{satan}->{del_user}->execute($user_name);
		}	
		
		# user in pam database
		if (defined $user_in{pam}) {
			### Doing pam db statements
			$db->{pam}->{del_user}->execute($uid);
			$db->{pam}->{del_group}->execute($uid);
			$db->{pam}->{del_user_group}->execute($uid);
			$db->{pam}->{drop_user}->execute("$uid-passwd");
			$db->{pam}->{drop_user}->execute("$uid-shadow");
		}
	
		# return true on success
		1;
	}
	or do {
		return "Cannot delete user $user_name ($uid) from database. Database error tutaj: $@";
	};
	
	commit($db);
	return;
}

sub passwd {
	my ($self, @args) = @_;
	my $db = $self->{db};
	
	# satan admin satan passwd <user_name> [ user_password yes|<password> ] [ satan_key yes|<key> ] [ mail yes|no ]
	my $user_name = shift @args or return "Username not specified. Cannot proceed.";
	   $user_name = lc $user_name;
	
	my $bad_username = validate_username($user_name);
	   $bad_username and return "Wrong username. $bad_username.";
	
        # check if arguments are in key-value format
        if (@args % 2) {
                return "Uneven number of arguments. Only key-value accepted.";
        }

        # store key-value arguments as hash
        my %value_of = @args;

	### Arguments: %value_of

	# no arguments
	if (not defined $value_of{user_password} and
	    not defined $value_of{satan_key}) {
		$value_of{user_password} = chars($MINLEN, $MAXLEN);
		$value_of{satan_key}     = chars($MINLEN, $MAXLEN); 
	}

	# db statements
	my %db_statement_for = (
		user_password  => 'pam',
		satan_key      => 'satan'
	);
	
	foreach my $type ( qw(user_password satan_key) ) {
		if (defined $value_of{$type}) {
			# generate password if specified as 'yes'
			if ($value_of{$type} eq 'yes') {
				$value_of{$type} = chars($MINLEN, $MAXLEN);	
			} 

			# check complexity of password
			my $password = $value_of{$type};
			my ($name) = split /_/, $type;
			    $name  = ucfirst $name;

			my $bad_password = IsBadPassword($value_of{$type});
			   $bad_password and return  "$name password is too simple: $bad_password.";	

			# crypt password
			if ($type eq 'user_password') {
				$password = crypt_password($value_of{$type});
			}
	
			# check if user exists
			my $statement = $db_statement_for{$type};
			$db->{$statement}->{check_user}->execute(undef, $user_name);
			if (!$db->{$statement}->{check_user}->rows) {
				return "User $user_name does NOT exist in $statement database.";
			}
		        $db->{$statement}->{check_user}->finish;
			
			# change password 
			$db->{$statement}->{change_passwd}->execute($password, $user_name) 
				or return "Cannot change password. Database error: $@.";
		}
	}
	
	# prepare user data 
	$self->{data} = \%value_of;

	# commit 
	commit($db);	
	return;
}

sub _get_data {
        my $self = shift;
        return $self->{data} || '';
}

1;
