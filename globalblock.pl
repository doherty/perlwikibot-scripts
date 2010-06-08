#!/usr/bin/perl
use strict;
use warnings;

use utf8;
use Carp;
use Getopt::Long;
use Pod::Usage;
use Config::General qw(ParseConfig);

use MediaWiki::Bot 3.2.0;
use MediaWiki::Bot::Plugin::Steward 0.0.1;

my $VERSION = '0.0.1';

=head1 NAME

globalblock.pl - Places, alters, and removes global blocks.

=head1 SYNOPSIS

globalblock.pl --ip 127.0.0.1 --no-anon-only --expiry "3 months" --summary "Vandals!"

Options:
    --help              Opens this man page and exit
    --version           Print version information and exit
    --dry-run           Do everything but edit
    --debug             Print debug output
    --target            The target IP/range
    --(no)-block        Whether to block or un-block the IP/range
    --(no)-anon-only    Whether the block shoudl apply only to anonymous users or not
    --summary           The log reason to use
    --username          Sets a non-default username
    --password          Request a password prompt

=head1 DESCRIPTION

B<globalblock.pl> allows those with access to a steward account to place, alter,
and remove global IP blocks.

You can set the IP/range to target and the log reason to use with --target and
--summary respectively. You can override the default account to use with
--username, and password with --password.

For security reasons, I<avoid> putting your password on the command line.
This will reveal your password to anyone on your system capable of viewing
process data. While this is safe for single-user systems, it is not on
multi-user systems. Instead, omit the password itself, and the script will
interactively prompt you for it:

    u@h:~$ perl globalblock.pl --password
    [globalblock.pl] password:

Non-interactive use (from cronjobs, for example) should set the password in
F<config/main.conf>.

Note that a password will only be used from F<config/main.conf> if it is in a
block for the username being used.

=head1 OPTIONS

=cut

my $help;
my $version;
my $dry_run;
my $debug;
my $block;
my $anon_only;
my $target;
my $expiry;
my $summary;
my $clobber;
my $username;
my $password;

GetOptions(
    'help|h|?'          => \$help,
    'version|v'         => \$version,
    'dry-run'           => \$dry_run,
    'debug|verbose'     => \$debug,
    'block!'            => \$block,
    'anon-only|ao!'     => \$anon_only,
    'ip|target=s'       => \$target,
    'expiry|length=s'   => \$expiry,
    'summary|reason=s'  => \$summary,
    'clobber!'          => \$clobber,
    'username=s'        => \$username,
    'password:s'        => \$password,  # We can ask for it interactively!
);
unless ($target) {
    die "fatal: --target is not optional" unless ($help or $version);
}

=over 4

=item B<--help>, -h, -?

Opens this man page and exits.

=cut

# If they asked for help, give them a manpage generated from POD in this file. Nifty!
pod2usage(
    -verbose => 2,
) if $help;

=item B<--version>, -v

Prints the version number and exits.

=cut

if ($version) {
    require File::Basename;
    my $script = File::Basename::basename($0);
    print "$script version $VERSION\n" and exit;
}

=item B<--debug>, --verbose

Ask the script to print debugging information about what it does.

=item B<--dry-run>

Do everything except actually make the edit.

=item B<--block>, --no-block

Whether to block or unblock the target. Default is to block.

=item B<--target>, --ip

The IP/range to (un)block.

=item B<--anon-only>, --ao

=item B<--no-anon-only>, --no-ao

Whether to block only anonymous users, or all users. Default is to softblock
(anon-only).

=item B<--summary>

Sets an edit summary to use instead of the default (which can be configured
in F<config/globalblock.conf>.

=item B<--expiry>, --length

How long to block them for. Default is 31 hours; configurable in
F<config/globalblock.conf>.

=item B<--clobber>, --no-clobber

Whether or not do overwrite a pre-existing block. Default is to not clobber,
and instead output an informational message.

=item B<--username>

Use a username other than the one set in F<config/main.conf>. If you specify
--username without --password, login will be attempted by searching for cookies
for that username. Login with password will be attempted if that fails and
there is a password provided in a block for the username you provided on the
command line.

=item B<--password>

Prompt for a password to use. You I<can> put the password on the command line
directly, but you B<shouldn't!>

=cut

if (defined($password)) {
    require Term::ReadKey;
    require File::Basename;
    my $script = File::Basename::basename($0);

    print "[$script] password: ";
    Term::ReadKey::ReadMode('noecho');      # Don't show the password
    $password = Term::ReadKey::ReadLine(0);
    Term::ReadKey::ReadMode('restore');     # Don't bork their terminal
    print "\n";
}

=back

=head1 EXAMPLES

The simplest invocation uses all default values:

    perl globalblock.pl --target "127.0.0.1"

You may want to use a special edit summary, overwriting pre-existing blocks:

    perl globalblock.pl --target "192.168.0.0/24" --summary "Vandalism" --clobber

To use a different account:

    perl globalblock.pl --username="My other account" --password

=cut

# Currently it is an error to use --username without --password. But shouldn't
# we at least attempt to log in with cookies for that username if we have any?
#die "You must use --password if you use --username" if (!$password and $username);
my $use_cookies = 1;
$use_cookies = 0 if ($username or $password);

if (!$username or !$password) {
    warn 'Reading config/main.conf' if $debug;
    my %main = ParseConfig (
        -ConfigFile     => 'config/main.conf',
        -LowerCaseNames => 1,
        -AutoTrue       => 1,
        -UTF8           => 1,
    );
    $username = $main{'default'}{'steward'} unless $username; warn "Using $username" if $debug;
    die "I can't figure out what account to use! Try setting steward in config/main.conf, or use --username" unless $username;
    die "There's no block for $username and you didn't specify enough data on the command line to continue" unless $main{'steward'}{$username};

    $password = $main{'steward'}{$username}{'password'} if (!$password); warn "Setting \$password" if $debug;
}

unless ($summary and defined($block) and defined($anon_only) and $expiry and defined($clobber)) {
    warn 'Reading config/globalblock.conf' if $debug;
    my %conf = ParseConfig (
        -ConfigFile     => 'config/globalblock.conf',
        -LowerCaseNames => 1,
        -AutoTrue       => 1,
        -UTF8           => 1,
    );

    $expiry = $conf{'expiry'} unless $expiry;
    warn "Setting \$expiry to $expiry" if $debug;

    $block = $conf{'block'} unless defined($block);
    warn "Setting \$block to $block" if $debug;

    $summary = $conf{'summary'} unless $summary;
    warn "Setting \$summary to '$summary'" if $debug;

    $anon_only = $conf{'anon-only'} unless defined($anon_only);
    warn "Setting \$anon_only to $anon_only" if $debug;

    $clobber = $conf{'clobber'} unless defined($clobber);
    warn "Setting \$clobber to $clobber" if $debug;
}

my $bot = MediaWiki::Bot->new({
    operator    => $username,
    protocol    => 'https',
    host        => 'secure.wikimedia.org',
    path        => 'wikipedia/meta/w',
    login_data  => { username => $username, password => $password },
}) or die "not logged in";
$bot->{'debug'} = $debug;

die <<"END" if $dry_run;
This is where we would attempt to submit the following:
\$bot->g_block({
    ip     => $target,
    ao     => $anon_only,
    reason => '$summary',
    expiry => '$expiry',
});
on $bot->{'host'}
with $username
END

warn "Attempting to set global block..." if $debug;
my $res;
if ($block) {
    $res = $bot->g_block({
        ip     => $target,
        ao     => $anon_only,
        reason => $summary,
        expiry => $expiry,
    }) or die "Submit failed";
}
else {
    $res = $bot->g_unblock({
        ip      => $target,
        reason  => $summary,
    }) or die "Submit failed";
}
=head1 FILES

The script reads F<config/main.conf> to get default values for username and
password. All other defaults are read from F<config/globalblock.conf>.

=head1 AUTHOR

Written by Mike.lifeguard <mike.lifeguard@gmail.com>.

=head1 COPYRIGHT

Copyright 2010 Mike.lifeguard <mike.lifeguard@gmail.com>.

=head1 LICENSE

GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.

This is free software; you are free to change and redistribute it in accordance
with the license. There is NO WARRANTY, to the extent permitted by law.

=head1 BUGS

None known. Bug reports and feature requests should go to
L<http://bugzilla.hashbang.ca/enter_bug.cgi?product=Perlwikibot-scripts>.

