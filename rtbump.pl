#!/usr/bin/env perl
#
# Copyright 2020 Kurt Kanzenbach <kurt@kmk-computers.de>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

use strict;
use warnings;
use version;
use utf8;
use IPC::Cmd qw(run);
use Data::Dumper;
use File::Basename;
use File::Copy;
use Getopt::Long;
use Term::ANSIColor qw(:constants);

# config
my (%rt_branches, $verbose, $branch, $dry_run, $help, $linux_dir,
    $gentoo_dir, $rt_sources_dir);

$linux_dir      = "$ENV{HOME}/git/linux";
$gentoo_dir     = "$ENV{HOME}/git/gentoo";
$rt_sources_dir = "$gentoo_dir/sys-kernel/rt-sources";

%rt_branches = (
    4.4 => {
        ebuild => "rt-sources-4.4.249_p212.ebuild",
    },
    4.9 => {
        ebuild => "rt-sources-4.9.247_p162.ebuild",
    },
    4.14 => {
        ebuild => "rt-sources-4.14.214_p104.ebuild",
    },
    4.19 => {
        ebuild => "rt-sources-4.19.165_p70.ebuild",
    },
    5.4 => {
        ebuild => "rt-sources-5.4.84_p47.ebuild",
    },
    5.10 => {
        ebuild => "rt-sources-5.10.4_p22.ebuild"
    },
);

sub print_usage_and_die
{
    select STDERR;

    local $| = 1;

    print <<"EOF";
usage: $0 [options]

options:
    --branch,  -b: The branch created
    --dry_run, -d: Dry run
    --help,    -h: Show this help
    --verbose, -v: Verbose output
EOF

    exit -1;
}

sub get_args
{
    GetOptions("help"     => \$help,
               "branch=s" => \$branch,
               "dry_run"  => \$dry_run,
               "verbose"  => \$verbose,
              ) || print_usage_and_die();

    print_usage_and_die() if $help;

    return;
}

sub kurt_err
{
    my ($msg) = @_;
    my (undef, undef, undef, $sub)  = caller(1);
    my (undef, $file, $line, undef) = caller(0);

    print_red("[ERROR in $sub $file:$line]: $msg\n");

    exit -1;
}

sub print_red
{
    my ($msg) = @_;

    print STDERR BOLD RED "$msg", RESET;

    return;
}

sub print_green
{
    my ($msg) = @_;

    print BOLD GREEN "$msg", RESET;

    return;
}

sub print_bold
{
    my ($msg) = @_;

    print BOLD "$msg", RESET;

    return;
}

sub cmd_ex
{
    my ($cmd) = @_;
    my ($success, $error_message, $full_buf, $stdout_buf, $stderr_buf) =
        run(command => $cmd, verbose => $verbose);

    kurt_err("Command \"$cmd\" failed") unless $success;

    return [ $stdout_buf, $stderr_buf ];
}

sub cmd
{
    my ($cmd) = @_;
    my ($success, $error_message, $full_buf, $stdout_buf, $stderr_buf) =
        run(command => $cmd, verbose => $verbose);

    return [ $success, $stdout_buf, $stderr_buf ];
}

sub update_linux_repo
{
    chdir $linux_dir || kurt_err("Failed to change dir into $linux_dir: $!");

    print "Update Linux repo...\n";
    cmd_ex("git remote update");

    return;
}

sub update_gentoo_repo
{
    chdir $gentoo_dir || kurt_err("Failed to change dir into $gentoo_dir: $!");

    print "Update Gentoo repo...\n";
    cmd_ex("git checkout master");
    cmd_ex("git remote update");
    cmd_ex("git merge --ff upstream/master");

    return;
}

sub create_gentoo_repo_branch
{
    my ($branch) = @_;

    $branch = "rtbump-" . int(rand(10000)) unless $branch;

    chdir $gentoo_dir || kurt_err("Failed to change dir into $gentoo_dir: $!");

    print "Creating branch ";
    print_green("$branch");
    print "...\n";
    cmd_ex("git checkout -b $branch") unless $dry_run;

    return;
}

sub rt_version_to_int
{
    my ($rt_version) = @_;
    my ($major, $minor, $stable, $rt);

    unless (($major, $minor, $stable, $rt) =
            $rt_version =~ /v(\d+)\.(\d+)\.(\d+)-rt(\d+)/x) {
        return 0;
    }

    return 0 if $rt_version =~ /rebase|patches/x;

    return $major * 1000 + $minor * 100 + $stable * 10 + $rt;
}

sub get_latest_rt_release
{
    my ($branch) = @_;
    my ($cmd, @tags);

    chdir $linux_dir || kurt_err("Failed to change dir into $linux_dir: $!");

    $cmd = cmd_ex("git tag -l 'v$branch*rt*'");

    @tags = split /\n/x, $cmd->[0]->[0];
    @tags = sort { rt_version_to_int($a) <=> rt_version_to_int($b) } @tags;

    return pop @tags;
}

sub rt_version_to_gentoo
{
    my ($rt_version) = @_;
    my ($major, $minor, $stable, $rt);

    unless (($major, $minor, $stable, $rt) =
            $rt_version =~ /v(\d+)\.(\d+)\.(\d+)-rt(\d+)/x) {
        kurt_err("Invalid rt version $rt_version");
    }

    return "rt-sources-" . "$major" . "." . "$minor" . "." . "$stable" .
        "_p" . $rt . ".ebuild";
}

sub main
{
    get_args();

    update_linux_repo();
    update_gentoo_repo();
    create_gentoo_repo_branch($branch);

    foreach my $branch (keys %rt_branches) {
        my ($latest, $ebuild);

        $latest = get_latest_rt_release($branch);
        $ebuild = rt_version_to_gentoo($latest);

        chdir $rt_sources_dir ||
            kurt_err("Failed to change to $rt_sources_dir: $!");

        next if -e $ebuild;

        # create ebuild
        copy($rt_branches{$branch}{ebuild}, $ebuild) ||
            kurt_err("Copy failed: $!") unless $dry_run;
        print "Created new ebuild ";
        print_green("$ebuild\n");

        # Add the ebuild, generate manifest and run repoman
        print "Running repoman...\n";
        cmd_ex("git add $ebuild") unless $dry_run;
        cmd_ex("repoman ci -m 'sys-kernel/rt-sources: Add rt sources $latest'")
            unless $dry_run;

        # Try to build it
        print "Merge it..\n";
        cmd_ex("sudo ebuild $ebuild clean merge") unless $dry_run;

        # Cleanup
        print "Unmerge it..\n";
        cmd_ex("sudo ebuild $ebuild unmerge") unless $dry_run;
    }

    return;
}

main();

exit 0;
