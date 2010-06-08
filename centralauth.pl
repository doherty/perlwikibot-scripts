#!/usr/bin/perl
use strict;
use warnings;

use utf8;
use Carp;
use Getopt::Long;
use Pod::Usage;
use Config::General qw(ParseConfig);

use MediaWiki::Bot 3.2.1;
use MediaWiki::Bot::Plugin::Steward 0.0.2;

my $VERSION = '0.0.1';

=head1 NAME

centralauth.pl - Locks (and optionally hides) global accounts

=head1 SYNOPSIS

centralauth.pl --target "Mike.lifeguard is a nazi." --hide=2

Options:
    --help      Opens this man page and exit
    --version   Print version information and exit
    --dry-run   Do everything but edit
    --debug     Print debug output
    --(no-)lock Whether to lock or not
    --hide      How hard to hide the account
    --nuke      Shorthand for --lock --hide=2
    --target    The target account
    --summary   The log reason to use
    --username  Sets a non-default username
    --password  Request a password prompt

=head1 DESCRIPTION

B<centralauth.pl> allows those with access to a steward account to lock accounts.

You can set the user to target and the log reason to use with --target and
--summary (alias --reason) respectively. You can override the default
account to use with --username, and password with --password.

For security reasons, I<avoid> putting your password on the command line.
This will reveal your password to anyone on your system capable of viewing
process data. While this is safe for single-user systems, it is not on
multi-user systems. Instead, omit the password itself, and the script will
interactively prompt you for it:

    u@h:~$ perl centralauth.pl --password
    [centralauth.pl] password:

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
my $target;
my $lock;
my $hide;
my $nuke;
my $summary;
my $username;
my $password;

GetOptions(
    'help|h|?'          => \$help,
    'version|v'         => \$version,
    'dry-run'           => \$dry_run,
    'debug|verbose'     => \$debug,
    'target=s'          => \$target,
    'lock!'             => \$lock,
    'hide:i'            => \$hide,
    'nuke|stab|os'      => \$nuke,
    'summary|reason=s'  => \$summary,
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

=item B<--target>

The target global account. Be sure to quote properly.

=item B<--lock>

=item B<--unlock>, --no-lock

Whether to lock the account, or unlock it. Default is to lock, but can be
changed in F<config/centralauth.conf>.

=item B<--hide>

How hard to hide the account. C<--hide> or C<--hide=1> hides the account on
public lists. C<--hide=2> hides the account completely (use of this option
must comply with the steward policy: L<http://meta.wikimedia.org/wiki/Stewards_policy>.
C<--hide=0> means no hiding at all, and is the default (but can be changed
in F<config/centralauth.conf>.

=item B<--nuke>, --stab, --os

These are short forms for S<--lock --hide 2>, and override those settings
completely. It also uses a different default reason, taken from
F<config/centralauth.conf>.

=item B<--summary>

Sets an edit summary to use instead of the default (which can be configured
in F<config/centralauth.conf>.

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

    perl centralauth.pl --target "Here's a username to lock"

You may want to use a special edit summary, and oversight the account:

    perl centralauth.pl --target "Here's a username" --summary "Abusive username" --hide=2

To use a different account:

    perl centralauth.pl --username="My other account" --password

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

unless ($summary and defined($lock) and defined($hide)) {
    warn 'Reading config/centralauth.conf' if $debug;
    my %conf = ParseConfig (
        -ConfigFile     => 'config/centralauth.conf',
        -LowerCaseNames => 1,
        -AutoTrue       => 1,
        -UTF8           => 1,
    );

    $lock = $conf{'lock'} unless defined($lock);
    warn "Setting \$lock to $lock" if $debug;

    $hide = $conf{'hide'} unless defined($hide);
    warn "Setting \$hide to $hide" if $debug;
    $hide = 2 if ($hide > 2);

    unless ($summary) {
        if ($nuke) {
            $summary = $conf{'nukesummary'};
        }
        else {
            $summary = $conf{'summary'};
        }
    }
    warn "Setting \$summary to '$summary'" if $debug;
}
if ($nuke) { # A special shorthand option
    warn "--nuke overrides --lock and --hide!" if $debug;
    $lock = 1;
    $hide = 2;
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
\$bot->ca_lock({
    user        => $target,
    lock        => $lock,
    hide        => $hide,
    reason      => $summary,
});
on $bot->{'api'}->{'config'}->{'api_url'}
with $username
END

warn "Submitting CentralAuth form..." if $debug;
$bot->ca_lock({
    user        => $target,
    lock        => $lock,
    hide        => $hide,
    reason      => $summary,
}) or die "Submit failed";

=head1 FILES

The script reads F<config/main.conf> to get default values for username and
password. All other defaults are read from F<config/centralauth.conf>.

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

