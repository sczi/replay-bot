#!/usr/bin/perl -w

use Net::Telnet;
use Time::HiRes qw(usleep nanosleep gettimeofday tv_interval);

sub wait_for_move_and_drops {
    my $piece = shift;
    while (1) {
        ($trash, $match) = $t->waitfor('/\(\d+:\d+\)|white \[.*?\] black \[.*?\]|resigns}|checkmated}/');
        if ($match =~ /\d+:\d+/) {
            return 0;
        } elsif ($match =~ /resigns|checkmated/) {
            return 1;
        } else {
            $match =~ /$color \[(.*?)\]/i;
            $piece_list = $1;
            if ($piece) {
                return 0 if $piece_list =~ /$piece/;
            }
        }
    }
}

sub SC {
    my $arr = shift;
    my $A = shift;
    my $B = shift;
    $arr->[$B] ^= $arr->[$A] ^= $arr->[$B];
    $arr->[$A] ^= $arr->[$B];
}

sub timeseal {
    #my $s = shift;
    #return $s;
    my @s = split //, shift;
    my $l = scalar(@s);
    my @key = split //, "Timestamp (FICS) v1.0 - programmed by Henrik Gram.";
    $s[$l++] = chr(0x18);
    my ($secs, $microsecs) = gettimeofday;
    my $timeseal_time = sprintf ("%ld", ($secs % 10000) * 1000 + $microsecs / 1000);
    push @s, (split //, $timeseal_time);
    $l += length $timeseal_time;
    $s[$l++] = chr(0x19);
    for (;$l % 12; $l++) {
        $s[$l] = '1';
    }
    for (my $n = 0; $n < $l; $n += 12) {
        SC(\@s, $n + 0, $n + 11);
        SC(\@s, $n + 2, $n + 9);
        SC(\@s, $n + 4, $n + 7);
    }
    for (my $n = 0; $n < $l; $n++) {
        $s[$n] = chr(((ord($s[$n]) | 0x80) ^ ord($key[$n % 50])) - 32);
    }
    $s[$l++] = chr(0x80);

    return (join '', @s);
}
sub decode_timeseal {
    my $str = shift;
    my @key = split //, "Timestamp (FICS) v1.0 - programmed by Henrik Gram.";
    my @str = split //, $str;
    # take off \x80\x0a
    pop @str;
    my $offset = (ord (pop @str)) - 0x80;
    print "offset is $offset\n";
    #for(n=0;n<l;n++)
    #    s[n]=((s[n]|0x80)^key[n%50])-32;
    for (my $n = 0; $n < @str; $n++) {
        $str[$n] = chr( ((ord($str[$n]) + 32) ^ ord($key[($n + $offset) % 50])) & ~0x80);
    }
    #for(n=0;n<l;n+=12)
    #    SC(n,n+11), SC(n+2,n+9), SC(n+4,n+7);
    for (my $n = 0; $n < @str; $n += 12) {
        SC(\@str, $n + 0, $n + 11);
        SC(\@str, $n + 2, $n + 9);
        SC(\@str, $n + 4, $n + 7);
    }
    $str = join '', @str;
    # don't include the timestamp
    #for $i (split //, $str) {
        #printf "%02X\n", ord($i);
    #}
    $str = substr $str, 0, (index $str, "\x18");
    return $str;
}

if (@ARGV != 6 && @ARGV != 7) {
    die "usage: $0 username password partner gamename game.bpgn timeseal_string [opponent]\n";
}

my ($username, $password, $partner, $gamename, $bpgn_glob, $timeseal_hello, $opponent) = @ARGV;

$t = new Net::Telnet (Prompt => '/fics% $/', Timeout => undef);
$t->open(Host => 'freechess.org', Port => 5000);
$t->print(timeseal($timeseal_hello));
$t->waitfor('/login: ?$/');
$t->print(timeseal("$username"));
$t->waitfor('/(password: ?$)|(press return)/i') or die $t->lastline();
$t->print(timeseal("$password"));
$t->print(timeseal('set style 8'));
$t->print(timeseal('set interface Thief 1.25'));
$t->print(timeseal('set bugopen 1'));
$t->print(timeseal('set seek 0'));
$t->print(timeseal('set open 1'));

# wait for partner to sign on and partner him
while (1) {
    $t->print(timeseal("finger $partner"));
    ($trash, $matched) = $t->waitfor('/(There is no player matching the name|Finger of|On for)/');
    last if $matched =~ /On for/;
    sleep 1;
}
$t->print(timeseal("partner $partner"));
print "partnered\n";

while (1) {
    #$skip = 1;
    for $bpgn (glob $bpgn_glob) {
        print "play game: $bpgn\n";
        #next if $skip and !($bpgn =~ /bugdb_2344484.bpgn/);
        #$skip = 0;
        open FIN, "<", $bpgn;
        undef $/;
        $file = <FIN>;
        if ($file =~ /WhiteA "$gamename"/) {
            $char = 'A';
            $color = 'White';
        } elsif ($file =~ /BlackA "$gamename"/) {
            $char = 'a';
            $color = 'Black';
        } elsif ($file =~ /WhiteB "$gamename"/) {
            $char = 'B';
            $color = 'White';
        } elsif ($file =~ /BlackB "$gamename"/) {
            $char = 'b';
            $color = 'Black';
        } else {
            die "couldn't find player $gamename in the game\n";
        }

        @moves = $file =~ /\d+$char\. (.*?){/g;
        @times = $file =~ /\d+$char\. .*?{(.*?)}/g;

        if ($opponent) {
            # wait for opps to sign on and match them
            while(1) {
                print "waiting for opps\n";
                last if (join '', $t->cmd(timeseal("bugwho p"))) =~ /Partnerships not playing bughouse.*?$opponent.*? displayed/is;
                sleep 1;
            }
            print "sending match request\n";
            $t->print(timeseal("match $opponent bughouse 2 0 $color\n"));
        } else {
            ($trash, $matched) = $t->waitfor('/You can "accept" or "decline"|partner accepts the match/');
            if ($matched =~ /You can "accept" or "decline"/) {
                $t->print(timeseal('accept'));
            }
        }

        print "match started\n";

        if ($color eq 'Black') {
            print "Black so waiting for opponents move\n";
            wait_for_move_and_drops();
            $t->print(timeseal("\x02\x39"));
        }
        $lasttime = 120;
        for $i (0..$#moves) {
            # wait for opponents move
            last if wait_for_move_and_drops();
            $t->print(timeseal("\x02\x39"));
            # sleep
            usleep(($lasttime - $times[$i]) * 1000000 * 0.9);
            $lasttime = $times[$i];
            # move
            if ($moves[$i] =~ /(.)@/) {
                $piece = $1;
                print "preparing to drop $piece\n";
                print "pieces in hand: $piece_list\n";
                if (! ($piece_list =~ /$piece/)) {
                    print "waiting for the drop\n";
                    last if wait_for_move_and_drops($piece);
                    $t->print(timeseal("\x02\x39"));
                }
            }
            $t->print(timeseal($moves[$i]));
            print "Moved: $moves[$i]\n";
            last if wait_for_move_and_drops();
            $t->print(timeseal("\x02\x39"));
        }
        print "Done with Game\n";

        $t->print(timeseal("resign")) if ($file =~ "$gamename resigns");
    }
}
