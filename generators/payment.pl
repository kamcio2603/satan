#!/usr/bin/perl 

use warnings;
use strict;
use lib('..');
use Satan::Tools;
use Text::Template;
use DBI;
use feature 'switch';
use Data::Dumper;
use Email::Send;
use Encode::MIME::Header;
use Encode qw{encode decode};
use DateTime;
$|++;

my $dbh_pay    = DBI->connect("dbi:mysql:my6667_pay;mysql_read_default_file=/root/.my.pay.cnf",undef,undef,{ RaiseError => 1, AutoCommit => 0});
my $dbh_system = DBI->connect("dbi:mysql:rootnode;mysql_read_default_file=/root/.my.system.cnf",undef,undef,{ RaiseError => 1, AutoCommit => 0 });

my $payu_get  = $dbh_pay->prepare("SELECT login, trans_id, trans_amount, trans_desc2, trans_pay_type, DATE(trans_create) FROM payu WHERE trans_status=99 AND done=0");
my $payu_done = $dbh_pay->prepare("UPDATE payu SET done=1 WHERE trans_id=?");

my $payment_add   = $dbh_system->prepare("INSERT INTO payments(uid,trans_id,date,type,bank,amount,currency) VALUES (?,?,?,?,?,?,?)");
my $payment_check = $dbh_system->prepare("SELECT trans_id FROM payments WHERE trans_id=?");

my $uid_check  = $dbh_system->prepare("SELECT id,uid,mail,lang,UNIX_TIMESTAMP(valid),block,del FROM users LEFT JOIN uids USING(id) WHERE login=?");
my $uid_update = $dbh_system->prepare("UPDATE uids SET block=0, del=0, valid=? WHERE uid=?");

my $user_update = $dbh_system->prepare("UPDATE users SET discount=0 WHERE id=?");

my $event_add = $dbh_system->prepare("INSERT INTO events(uid,date,daemon,event) VALUES(?,NOW(),'adduser',?)");

# payu
$payu_get->execute;
while(my($login,$trans_id,$trans_amount, $trans_desc2, $trans_pay_type, $date) = $payu_get->fetchrow_array) {
	#next unless $login eq 'ahes';
	print $login."\n";
	
	# add dot to price
	my $amount = $trans_amount;
	   $amount =~ s/(\d\d)$/\.$1/;
	   $amount =~ s/^\./0\./;
	
	# set period 
	my $period;
	given($trans_desc2) {
		when('year')    { $period = 12 }
		when('quarter') { $period =  3 }
		default         { die "No desc2. Cannot set period" }
	}

	# check if payment exists
	$payment_check->execute($trans_id);
	if($payment_check->rows) {
		#$payu_done->execute->$trans_id;
		print "payment exists\n";
		next;
	}

	# check if user exists
	$uid_check->execute($login);
	if(!$uid_check->rows) {
		# adduser
		# we need to add user
		print "we need to add user";
	}

	my($subject,$body);
	may($id,$uid,$mail,$lang,$valid,$block,$del) = @{$uid_check->fetchrow_arrayref};

	# calculate new expire date
	$valid = DateTime->from_epoch(epoch=>$valid)->add(months=>$period, days=>1)->ymd;

	if($block and $del) {
		# undel
		print 'need to be undeleted';
		next;
	} else {
		# prolong
		print "prolong\n";
		if(lc $lang eq 'pl') {
			$subject = "Rootnode - płatność zaakceptowana ($login)";
			$body = "Otrzymaliśmy twoją opłatę w wysokości ${amount}zł za konto '${login}' na Rootnode.\n"
			      . "Konto wygasa ${valid}.\n\n"
			      . "Dziękujemy.\n\n"
			      . "-- \nKochani Administratorzy\n"; 
		} else {
			$subject = "Rootnode - payment accepted ($login)";
			$body = "We have received your payment of ${amount}zl for '${login}' account on Rootnode.\n"
			      . "Account expires at ${valid}.\n\n"
			      . "Thank you.\n\n"
			      . "-- \nBeloved Administrators\n";
		}
	}
	
	my $headers = "To: $mail\n"
	            . "From: Rootnode <admins\@rootnode.net>\n"
	            . "Subject: ".encode("MIME-Header", decode('utf8',$subject))."\n"
	            . "MIME-Version: 1.0\n"
	            . "Content-Type: text/plain; charset=utf-8\n"
	            . "Content-Disposition: inline\n"
	            . "Content-Transfer-Encoding: 8bit\n"
	            . "X-Rootnode-Powered: God bless those who read headers!\n\n";
	
	my $message = decode('utf8', $headers.$body);
        
	$payment_add->execute($uid,$trans_id,$date,'payu',$trans_pay_type,$amount,'PLN');
	$payu_done->execute($trans_id);
	$uid_update->execute($valid, $uid);
	$user_update->execute($id);
	
	my $sender = Email::Send->new({mailer => 'SMTP'});
           $sender->mailer_args([Host => 'mail1.rootnode.net']);
       
	my $status = $sender->send($message) ? "Message sent to $mail" : "Message NOT sent to $mail.";
        $event_add->execute($uid,$status);
}
$dbh_system->commit;
$dbh_pay->commit;
