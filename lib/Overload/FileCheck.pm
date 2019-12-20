# Copyright (c) 2018, cPanel, LLC.
# All rights reserved.
# http://cpanel.net
#
# This is free software; you can redistribute it and/or modify it under the
# same terms as Perl itself. See L<perlartistic>.

package Overload::FileCheck;

use strict;
use warnings;

# ABSTRACT: override/mock perl file check -X: -e, -f, -d, ...

use Errno ();

use base 'Exporter';

BEGIN {

    # VERSION: generated by DZP::OurPkgVersion

    require XSLoader;
    XSLoader::load(__PACKAGE__);
}

use Fcntl (
    '_S_IFMT',     # bit mask for the file type bit field
                   #'S_IFPERMS',   # bit mask for file perms.
    'S_IFSOCK',    # socket
    'S_IFLNK',     # symbolic link
    'S_IFREG',     # regular file
    'S_IFBLK',     # block device
    'S_IFDIR',     # directory
    'S_IFCHR',     # character device
    'S_IFIFO',     # FIFO

    # qw{S_IRUSR S_IWUSR S_IXUSR S_IRWXU}
);

my @STAT_T_IX = qw{
  ST_DEV
  ST_INO
  ST_MODE
  ST_NLINK
  ST_UID
  ST_GID
  ST_RDEV
  ST_SIZE
  ST_ATIME
  ST_MTIME
  ST_CTIME
  ST_BLKSIZE
  ST_BLOCKS
};

my @CHECK_STATUS = qw{CHECK_IS_FALSE CHECK_IS_TRUE FALLBACK_TO_REAL_OP};

my @STAT_HELPERS = qw{ stat_as_directory stat_as_file stat_as_symlink
  stat_as_socket stat_as_chr stat_as_block};

our @EXPORT_OK = (
    qw{
      mock_all_from_stat
      mock_all_file_checks mock_file_check mock_stat
      unmock_file_check unmock_all_file_checks unmock_stat
      },
    @CHECK_STATUS,
    @STAT_T_IX,
    @STAT_HELPERS,
);

our %EXPORT_TAGS = (
    all => [@EXPORT_OK],

    # status code
    check => [@CHECK_STATUS],

    # STAT array indexes
    stat => [ @STAT_T_IX, @STAT_HELPERS ],
);

# hash for every filecheck we can mock
#   and their corresonding OP_TYPE
my %MAP_FC_OP = (
    'R' => OP_FTRREAD,
    'W' => OP_FTRWRITE,
    'X' => OP_FTREXEC,
    'r' => OP_FTEREAD,
    'w' => OP_FTEWRITE,
    'x' => OP_FTEEXEC,

    'e' => OP_FTIS,
    's' => OP_FTSIZE,     # OP_CAN_RETURN_INT
    'M' => OP_FTMTIME,    # OP_CAN_RETURN_INT
    'C' => OP_FTCTIME,    # OP_CAN_RETURN_INT
    'A' => OP_FTATIME,    # OP_CAN_RETURN_INT

    'O' => OP_FTROWNED,
    'o' => OP_FTEOWNED,
    'z' => OP_FTZERO,
    'S' => OP_FTSOCK,
    'c' => OP_FTCHR,
    'b' => OP_FTBLK,
    'f' => OP_FTFILE,
    'd' => OP_FTDIR,
    'p' => OP_FTPIPE,
    'u' => OP_FTSUID,
    'g' => OP_FTSGID,
    'k' => OP_FTSVTX,

    'l' => OP_FTLINK,

    't' => OP_FTTTY,

    'T' => OP_FTTEXT,
    'B' => OP_FTBINARY,

    # special cases for stat & lstat
    'stat'  => OP_STAT,
    'lstat' => OP_LSTAT,

);

my %MAP_STAT_T_IX = (
    st_dev     => ST_DEV,
    st_ino     => ST_INO,
    st_mode    => ST_MODE,
    st_nlink   => ST_NLINK,
    st_uid     => ST_UID,
    st_gid     => ST_GID,
    st_rdev    => ST_RDEV,
    st_size    => ST_SIZE,
    st_atime   => ST_ATIME,
    st_mtime   => ST_MTIME,
    st_ctime   => ST_CTIME,
    st_blksize => ST_BLKSIZE,
    st_blocks  => ST_BLOCKS,
);

# op_type_id => check
my %REVERSE_MAP;

my %OP_CAN_RETURN_INT   = map { $MAP_FC_OP{$_} => 1 } qw{ s M C A };
my %OP_IS_STAT_OR_LSTAT = map { $MAP_FC_OP{$_} => 1 } qw{ stat lstat };
#
# This is listing the default ERRNO codes
#   used by each test when the test fails and
#   the user did not provide one ERRNO error
#
my %DEFAULT_ERRNO = (
    'default' => Errno::ENOENT,    # default value for any other not listed
    'x'       => Errno::ENOEXEC,
    'X'       => Errno::ENOEXEC,

    # ...
);

# this is saving our custom ops
# optype_id => sub
my $_current_mocks = {};

sub import {
    my ( $class, @args ) = @_;

    # mock on import...
    my $_next_check;
    my @for_exporter;
    foreach my $check (@args) {
        if ( !$_next_check && $check !~ qr{^-} ) {

            # this is a valid arg for exporter
            push @for_exporter, $check;
            next;
        }
        if ( !$_next_check ) {

            # we found a key like '-e' in '-e => sub {} '
            $_next_check = $check;
        }
        else {
            # now this is the value
            my $code = $check;

            # use Overload::FileCheck -from_stat => \&my_stat;
            if ( $_next_check eq q{-from_stat} || $_next_check eq q{-from-stat} ) {
                mock_all_from_stat($code);
            }
            else {
                mock_file_check( $_next_check, $code );
            }

            undef $_next_check;
        }
    }

    # callback the exporter logic
    return __PACKAGE__->export_to_level( 1, $class, @for_exporter );
}

sub mock_all_file_checks {
    my ($sub) = @_;

    foreach my $check ( sort keys %MAP_FC_OP ) {
        next if $check =~ qr{^l?stat$};    # we should not mock stat
        mock_file_check(
            $check,
            sub {
                my (@args) = @_;
                return $sub->( $check, @args );
            }
        );
    }

    return 1;
}

sub mock_file_check {
    my ( $check, $sub ) = @_;

    die q[Check is not defined] unless defined $check;
    die q[Second arg must be a CODE ref] unless ref $sub eq 'CODE';

    $check =~ s{^-+}{};    # strip any extra dashes
                           #return -1 unless defined $MAP_FC_OP{$check}; # we should not do that
    die qq[Unknown check '$check'] unless defined $MAP_FC_OP{$check};

    my $optype = $MAP_FC_OP{$check};
    die qq[-$check is already mocked by Overload::FileCheck] if exists $_current_mocks->{$optype};

    $_current_mocks->{$optype} = $sub;

    _xs_mock_op($optype);

    return 1;
}

sub unmock_file_check {
    my (@checks) = @_;

    foreach my $check (@checks) {
        die q[Check is not defined] unless defined $check;
        $check =~ s{^-+}{};    # strip any extra dashes
        die qq[Unknown check '$check'] unless defined $MAP_FC_OP{$check};

        my $optype = $MAP_FC_OP{$check};

        delete $_current_mocks->{$optype};

        _xs_unmock_op($optype);
    }

    return 1;
}

sub mock_all_from_stat {
    my ($sub_for_stat) = @_;

    # then mock all -X checks to our custom
    mock_all_file_checks(
        sub {
            my ( $check, $f_or_fh ) = @_;

            # the main call
            my $return = _check_from_stat( $check, $f_or_fh, $sub_for_stat );

            # auto remock the OP (it could have been temporary unmocked to use -X _)
            _xs_mock_op( $MAP_FC_OP{$check} );

            return $return;
        }
    );

    # start by mocking 'stat' and 'lstat' call
    mock_stat($sub_for_stat);

    return 1;
}

sub _check_from_stat {
    my ( $check, $f_or_fh, $sub_for_stat ) = @_;

    my $optype = $MAP_FC_OP{$check};

    # stat would need to be called twice
    # 1/ we first need to check if we are mocking the file
    #   or if we let it fallback to the Perl OP
    # 2/ doing a second stat call in order to cache _

    my $can_use_stat;
    $can_use_stat = 1 if $check =~ qr{^[sfdMXxzACORWeorw]$};

    my $stat_or_lstat = $can_use_stat ? 'stat' : 'lstat';

    my (@mocked_lstat_result) = $sub_for_stat->( $stat_or_lstat, $f_or_fh );
    if (   scalar @mocked_lstat_result == 1
        && !ref $mocked_lstat_result[0]
        && $mocked_lstat_result[0] == FALLBACK_TO_REAL_OP ) {
        return FALLBACK_TO_REAL_OP;
    }

    # avoid a second callback to the user hook (do not really happen for now)
    local $_current_mocks->{ $MAP_FC_OP{$stat_or_lstat} } = sub {
        return @mocked_lstat_result;
    };

    # now performing a real stat call [ using the mocked stat function ]
    my ( @stat, @lstat );

    if ($can_use_stat) {
        no warnings;    # throw warnings with Perl <= 5.14
        @stat = stat($f_or_fh) if defined $f_or_fh;
    }
    else {
        no warnings;
        @lstat = lstat($f_or_fh) if defined $f_or_fh;
    }

    if ( $check eq 'r' ) {

        # -r  File is readable by effective uid/gid.
        #  return _cando(stat_mode, effective, &PL_statcache)
        #   return _cando( S_IRUSR, 1 )

        # ugly need a better way to do this...
        _xs_unmock_op($optype);
        return _to_bool( scalar -r _ );
    }
    elsif ( $check eq 'w' ) {

        # -w  File is writable by effective uid/gid.
        _xs_unmock_op($optype);
        return _to_bool( scalar -w _ );
    }
    elsif ( $check eq 'x' ) {

        # -x  File is executable by effective uid/gid.
        _xs_unmock_op($optype);
        return _to_bool( scalar -x _ );
    }
    elsif ( $check eq 'o' ) {

        # -o  File is owned by effective uid.
        _xs_unmock_op($optype);
        return _to_bool( scalar -o _ );
    }
    elsif ( $check eq 'R' ) {

        # -R  File is readable by real uid/gid.
        _xs_unmock_op($optype);
        return _to_bool( scalar -R _ );
    }
    elsif ( $check eq 'W' ) {

        # -W  File is writable by real uid/gid.
        _xs_unmock_op($optype);
        return _to_bool( scalar -W _ );
    }
    elsif ( $check eq 'X' ) {

        # -X  File is executable by real uid/gid.

        _xs_unmock_op($optype);
        return _to_bool( scalar -X _ );
    }
    elsif ( $check eq 'O' ) {

        # -O  File is owned by real uid.
        _xs_unmock_op($optype);
        return _to_bool( scalar -O _ );
    }
    elsif ( $check eq 'e' ) {

        # -e  File exists.
        # a file can only exists if MODE is set ?
        return _to_bool( scalar @stat && $stat[ST_MODE] );
    }
    elsif ( $check eq 'z' ) {

        # -z  File has zero size (is empty).

        # TODO: can probably avoid the extra called...
        #   by checking it ourself

        _xs_unmock_op($optype);
        return _to_bool( scalar -z _ );
    }
    elsif ( $check eq 's' ) {

        # -s  File has nonzero size (returns size in bytes).

        # fallback does not work with symlinks
        #   do the check ourself, which also save a few calls

        return $stat[ST_SIZE];
    }
    elsif ( $check eq 'f' ) {

        # -f  File is a plain file.
        return _check_mode_type( $stat[ST_MODE], S_IFREG );
    }
    elsif ( $check eq 'd' ) {

        # -d  File is a directory.

        return _check_mode_type( $stat[ST_MODE], S_IFDIR );
    }
    elsif ( $check eq 'l' ) {

        # -l  File is a symbolic link (false if symlinks aren't
        #    supported by the file system).

        return _check_mode_type( $lstat[ST_MODE], S_IFLNK );
    }
    elsif ( $check eq 'p' ) {

        # -p  File is a named pipe (FIFO), or Filehandle is a pipe.
        return _check_mode_type( $lstat[ST_MODE], S_IFIFO );
    }
    elsif ( $check eq 'S' ) {

        # -S  File is a socket.
        return _check_mode_type( $lstat[ST_MODE], S_IFSOCK );
    }
    elsif ( $check eq 'b' ) {

        # -b  File is a block special file.
        return _check_mode_type( $lstat[ST_MODE], S_IFBLK );
    }
    elsif ( $check eq 'c' ) {

        # -c  File is a character special file.
        return _check_mode_type( $lstat[ST_MODE], S_IFCHR );
    }
    elsif ( $check eq 't' ) {

        # -t  Filehandle is opened to a tty.
        _xs_unmock_op($optype);
        return _to_bool( scalar -t _ );
    }
    elsif ( $check eq 'u' ) {

        # -u  File has setuid bit set.
        _xs_unmock_op($optype);
        return _to_bool( scalar -u _ );
    }
    elsif ( $check eq 'g' ) {

        # -g  File has setgid bit set.
        _xs_unmock_op($optype);
        return _to_bool( scalar -g _ );
    }
    elsif ( $check eq 'k' ) {

        # -k  File has sticky bit set.

        _xs_unmock_op($optype);
        return _to_bool( scalar -k _ );
    }
    elsif ( $check eq 'T' ) {    # heuristic guess.. throw a die?

        # -T  File is an ASCII or UTF-8 text file (heuristic guess).

        #return CHECK_IS_FALSE if -d $f_or_fh;

        _xs_unmock_op($optype);
        return _to_bool( scalar -T *_ );
    }
    elsif ( $check eq 'B' ) {    # heuristic guess.. throw a die?

        # -B  File is a "binary" file (opposite of -T).

        return CHECK_IS_TRUE if -d $f_or_fh;

        # ... we cannot really know...
        # ... this is an heuristic guess...

        _xs_unmock_op($optype);
        return _to_bool( scalar -B *_ );
    }
    elsif ( $check eq 'M' ) {

        # -M  Script start time minus file modification time, in days.

        return CHECK_IS_NULL unless scalar @stat && defined $stat[ST_MTIME];
        return ( ( get_basetime() - $stat[ST_MTIME] ) / 86400.0 );

        #return int( scalar -M _ );
    }
    elsif ( $check eq 'A' ) {

        # -A  Same for access time.
        #
        # ((NV)PL_basetime - PL_statcache.st_atime) / 86400.0
        return CHECK_IS_NULL unless scalar @stat && defined $stat[ST_ATIME];

        return ( ( get_basetime() - $stat[ST_ATIME] ) / 86400.0 );
    }
    elsif ( $check eq 'C' ) {

        # -C  Same for inode change time (Unix, may differ for other
        #_xs_unmock_op($optype);
        #return scalar -C *_;
        return CHECK_IS_NULL unless scalar @stat && defined $stat[ST_CTIME];

        return ( ( get_basetime() - $stat[ST_CTIME] ) / 86400.0 );
    }
    else {
        die "Unknown check $check.\n";
    }

    die "FileCheck -$check is not implemented by Overload::FileCheck...";

    return FALLBACK_TO_REAL_OP;
}

sub _to_bool {
    my ($s) = @_;

    return ( $s ? CHECK_IS_TRUE : CHECK_IS_FALSE );
}

sub _check_mode_type {
    my ( $mode, $type ) = @_;

    return CHECK_IS_FALSE unless defined $mode;
    return _to_bool( ( $mode & _S_IFMT ) == $type );
}

# this is a special case used to mock OP_STAT & OP_LSTAT
sub mock_stat {
    my ($sub) = @_;

    die q[First arg must be a CODE ref] unless ref $sub eq 'CODE';

    foreach my $opname (qw{stat lstat}) {
        my $optype = $MAP_FC_OP{$opname};
        die qq[No optype found for $opname] unless $optype;

        # plug the sub
        $_current_mocks->{$optype} = sub {
            my $file_or_handle = shift;
            return $sub->( $opname, $file_or_handle );
        };

        # setup the mock for the OP
        _xs_mock_op($optype);
    }

    return 1;
}

# just an alias to unmock stat & lstat at the same time
sub unmock_stat {
    return unmock_file_check(qw{stat lstat});
}

sub unmock_all_file_checks {

    if ( !scalar %REVERSE_MAP ) {
        foreach my $k ( keys %MAP_FC_OP ) {
            $REVERSE_MAP{ $MAP_FC_OP{$k} } = $k;
        }
    }

    my @mocks = sort map { $REVERSE_MAP{$_} } keys %$_current_mocks;
    return unless scalar @mocks;

    return unmock_file_check(@mocks);
}

# should not be called directly
# this is called from XS to check if one OP is mocked
# and trigger the callback function when mocked
my $_last_call_for;

sub _check {
    my ( $optype, $file, @others ) = @_;

    die if scalar @others;    # need to move this in a unit test

    # we have no custom mock at this point
    return FALLBACK_TO_REAL_OP unless defined $_current_mocks->{$optype};

    $file = $_last_call_for if !defined $file && defined $_last_call_for && !defined $_current_mocks->{ $MAP_FC_OP{'stat'} };
    my ( $out, @extra ) = $_current_mocks->{$optype}->($file);
    $_last_call_for = $file;

    # FIXME return undef when not defined out

    if ( defined $out && $OP_CAN_RETURN_INT{$optype} ) {
        return $out;          # limitation to int for now in fact some returns NVs
    }

    if ( !$out ) {

        # check if the user provided a custom ERRNO error otherwise
        #   set one for him, so a test could never fail without having
        #   ERRNO set
        if ( !int($!) ) {
            $! = $DEFAULT_ERRNO{ $REVERSE_MAP{$optype} || 'default' } || $DEFAULT_ERRNO{'default'};
        }

        #return undef unless defined $out;
        return CHECK_IS_FALSE;
    }

    return FALLBACK_TO_REAL_OP if !ref $out && $out == FALLBACK_TO_REAL_OP;

    # stat and lstat OP are returning a stat ARRAY in addition to the status code
    if ( $OP_IS_STAT_OR_LSTAT{$optype} ) {

        # .......... Stat_t
        # dev_t     st_dev     Device ID of device containing file.
        # ino_t     st_ino     File serial number.
        # mode_t    st_mode    Mode of file (see below).
        # nlink_t   st_nlink   Number of hard links to the file.
        # uid_t     st_uid     User ID of file.
        # gid_t     st_gid     Group ID of file.
        # dev_t     st_rdev    Device ID (if file is character or block special).
        # off_t     st_size    For regular files, the file size in bytes.
        # time_t    st_atime   Time of last access.
        # time_t    st_mtime   Time of last data modification.
        # time_t    st_ctime   Time of last status change.
        # blksize_t st_blksize A file system-specific preferred I/O block size for
        # blkcnt_t  st_blocks  Number of blocks allocated for this object.
        # ......

        my $stat      = $out // $others[0];    # can be array or hash at this point
        my $stat_is_a = ref $stat;
        die q[Your mocked function for stat should return a stat array or hash] unless $stat_is_a;

        my $stat_as_arrayref;

        # can handle one ARRAY or a HASH
        my $stat_t_max = STAT_T_MAX;
        if ( $stat_is_a eq 'ARRAY' ) {
            $stat_as_arrayref = $stat;
            my $av_size = scalar @$stat;
            if (
                $av_size                       # 0 is valid when the file is missing
                && $av_size != $stat_t_max
            ) {
                die qq[Stat array should contain exactly 0 or $stat_t_max values];
            }
        }
        elsif ( $stat_is_a eq 'HASH' ) {
            $stat_as_arrayref = [ (0) x $stat_t_max ];    # start with an empty array
            foreach my $k ( keys %$stat ) {
                my $ix = $MAP_STAT_T_IX{ lc($k) };
                die qq[Unknown index for stat_t struct key $k] unless defined $ix;
                $stat_as_arrayref->[$ix] = $stat->{$k};
            }
        }
        else {
            die q[Your mocked function for stat should return a stat array or hash];
        }

        return ( CHECK_IS_TRUE, $stat_as_arrayref );
    }

    return CHECK_IS_TRUE;
}

# accessors for testing purpose mainly
sub _get_filecheck_ops_map {
    return {%MAP_FC_OP};    # return a copy
}

######################################################
### stat helpers
######################################################

sub stat_as_directory {
    my (%opts) = @_;

    return _stat_for( S_IFDIR, \%opts );
}

sub stat_as_file {
    my (%opts) = @_;

    return _stat_for( S_IFREG, \%opts );
}

sub stat_as_symlink {
    my (%opts) = @_;

    return _stat_for( S_IFLNK, \%opts );
}

sub stat_as_socket {
    my (%opts) = @_;

    return _stat_for( S_IFSOCK, \%opts );
}

sub stat_as_chr {
    my (%opts) = @_;

    return _stat_for( S_IFCHR, \%opts );
}

sub stat_as_block {
    my (%opts) = @_;

    return _stat_for( S_IFBLK, \%opts );
}

sub _stat_for {
    my ( $type, $opts ) = @_;

    my @stat = ( (0) x 13 );    # STAT_T_MAX

    # set file type
    if ( defined $type ) {

        # _S_IFMT is used as a protection to do not flip outside the mask
        $stat[ST_MODE] |= ( $type & _S_IFMT );
    }

    # set permission using octal
    if ( defined $opts->{perms} ) {

        # _S_IFMT is used as a protection to do not flip outside the mask
        $stat[ST_MODE] |= ( $opts->{perms} & ~_S_IFMT );
    }

    # deal with UID / GID
    if ( defined $opts->{uid} ) {
        if ( $opts->{uid} =~ qr{^[0-9]+$} ) {
            $stat[ST_UID] = $opts->{uid};
        }
        else {

            $stat[ST_UID] = getpwnam( $opts->{uid} );
        }
    }

    if ( defined $opts->{gid} ) {
        if ( $opts->{gid} =~ qr{^[0-9]+$} ) {
            $stat[ST_GID] = $opts->{gid};
        }
        else {
            $stat[ST_GID] = getgrnam( $opts->{gid} );
        }
    }

    # options that we can simply copy to a slot
    my %name2ix = (
        size    => ST_SIZE,
        atime   => ST_ATIME,
        mtime   => ST_MTIME,
        ctime   => ST_CTIME,
        blksize => ST_BLKSIZE,
        blocks  => ST_BLOCKS,
    );

    foreach my $k ( keys %$opts ) {
        $k = lc($k);
        $k =~ s{^st_}{};
        next unless defined $name2ix{$k};

        $stat[ $name2ix{$k} ] = $opts->{$k};
    }

    return \@stat;
}

1;

=pod

=encoding utf-8

=begin markdown

[![](https://github.com/CpanelInc/Overload-FileCheck/workflows/linux/badge.svg)](https://github.com/CpanelInc/Overload-FileCheck/actions) [![](https://github.com/CpanelInc/Overload-FileCheck/workflows/macos/badge.svg)](https://github.com/CpanelInc/Overload-FileCheck/actions) [![](https://github.com/CpanelInc/Overload-FileCheck/workflows/windows/badge.svg)](https://github.com/CpanelInc/Overload-FileCheck/actions)

=end markdown

=head1 SYNOPSIS

Overload::FileCheck provides a way to mock one or more file checks.
It is also possible to mock stat/lstat functions using L<"mock_all_from_stat"> and let Overload::FileCheck
mock for you for any other -X checks.

By using mock_all_file_checks you can set a hook function to reply any -X check.

# EXAMPLE: examples/synopsis.pl

=head1 DESCRIPTION

Overload::FileCheck provides a hook system to mock Perl filechecks OPs

=begin HTML

<p><img src="https://travis-ci.org/CpanelInc/Overload-FileCheck.svg?branch=master" width="81" height="18" alt="Travis CI" /></p>

=end HTML

With this module you can provide your own pure perl code when performing
file checks using one of the -X ops: -e, -f, -z, ...

L<https://perldoc.perl.org/functions/-X.html>

    -r  File is readable by effective uid/gid.
    -w  File is writable by effective uid/gid.
    -x  File is executable by effective uid/gid.
    -o  File is owned by effective uid.
    -R  File is readable by real uid/gid.
    -W  File is writable by real uid/gid.
    -X  File is executable by real uid/gid.
    -O  File is owned by real uid.
    -e  File exists.
    -z  File has zero size (is empty).
    -s  File has nonzero size (returns size in bytes).
    -f  File is a plain file.
    -d  File is a directory.
    -l  File is a symbolic link (false if symlinks aren't
        supported by the file system).
    -p  File is a named pipe (FIFO), or Filehandle is a pipe.
    -S  File is a socket.
    -b  File is a block special file.
    -c  File is a character special file.
    -t  Filehandle is opened to a tty.
    -u  File has setuid bit set.
    -g  File has setgid bit set.
    -k  File has sticky bit set.
    -T  File is an ASCII or UTF-8 text file (heuristic guess).
    -B  File is a "binary" file (opposite of -T).
    -M  Script start time minus file modification time, in days.
    -A  Same for access time.
    -C  Same for inode change time (Unix, may differ for other
  platforms)

Also view pp_sys.c from the Perl source code, where are defined the original OPs.

In addition it's also possible to mock the Perl OP C<stat> and C<lstat>, read L</"Mocking stat and lstat"> section for more details.

=head1 Usage and Examples

When using this module, you can decide to mock filecheck OPs on import or later
at run time.

=head2 Mocking filecheck at import time

You can mock multiple filecheck at import time.
Note that the ':check' will import constants like:
CHECK_IS_TRUE, CHECK_IS_FALSE, FALLBACK_TO_REAL_OP
which are recommended return values to use in your hook functions.

# EXAMPLE: examples/mock-multiple-filecheck-import.t

=head2 Mocking filecheck at run time

You can also get a similar behavior by declaring the overload later at run time.

# EXAMPLE: examples/mock-multiple-filecheck-run.t

=head2 Check helpers to use in your callback function

In your callback function you should use the following helpers to return.

=over

=item B<CHECK_IS_FALSE>: use this constant when the test is false

=item B<CHECK_IS_TRUE>: use this when you the test is true

=item B<FALLBACK_TO_REAL_OP>: you want to delegate the answer to Perl itself :-)

=back

It's also possible to return one integer. Checks like C<-s>, C<-M>, C<-C>, C<-A> can return
any integers.

Example:

    use Overload::FileCheck q(:all);

    mock_file_check( '-s' => \&my_dash_s );

    sub my_dash_s {
        my ( $file_or_handle ) = @_;

        if ( $file_or_handle eq '/a/b/c' ) {
            return 42;
        }

        return FALLBACK_TO_REAL_OP;
    }

=head2 Tracing all file checks usage

You can trace all file checks in your codebase without altering it.

# EXAMPLE: examples/trace-code.pl

=head2 Mock one or more file checks: -e, -f

You can mock a single file check type like '-e', '-f', ...

# EXAMPLE: examples/mock-single-filecheck.pl

=head2 Mock check calls at import time

You can also mock the check functions at import time by providing a check test
and a custom function

# EXAMPLE: examples/mock-single-filecheck-at-import.pl

=head1 Mocking stat and lstat

=head2 How to mock stat?

Here is a short sample how you can mock stat and lstat.
This is an extract from the testsuite, Test2::* modules are
just there to illustrate the behavior. You should not necessary use them
in your code.

For more advanced samples, browse to the source code and check the test files
in t or examples directories.

# EXAMPLE: examples/mock-stat.pl

=head2 Convenient constants available when mocking stat

When mocking stat or lstat function your callback function should return one of the following

=over

=item either one ARRAY Ref containing 13 entries as described by the stat function (in the same order)

=item or an empty ARRAY Ref, if the file does not exist

=item or one HASH ref using one or more of the following keys: st_dev, st_ino, st_mode, st_nlink,
  st_uid, st_gid, st_rdev, st_size, st_atime, st_mtime, st_ctime, st_blksiz, st_blocks

=item or return FALLBACK_TO_REAL_OP when you want to let Perl take back the control for that file

=back

In order to manipulate the ARRAY ref and insert/update one specific entry, some constant are available
to access to the correct index via a 'name':

=over

=item ST_DEV

=item ST_INO

=item ST_MODE

=item ST_NLINK

=item ST_UID

=item ST_GID

=item ST_RDEV

=item ST_SIZE

=item ST_ATIME

=item ST_MTIME

=item ST_CTIME

=item ST_BLKSIZE

=item ST_BLOCKS

=back


=head2 Mocking all file checks from a single 'stat' function

A recommended option is to only mock the 'stat' and 'lstat' function
and let Overload::FileCheck mock for you all file checks: -e, -f, -s, -z, ...

By doing so, using '_' or '*_' (a.k.a. PL_defgv) in your filecheck would work without any extra effort.

    -d "/my/file" && -s _

Netherway some limitations exist. Indeed the checks '-B' and '-T' are using some heuristics to determine
if the file is a binary or a text. This would require more than just a simple stat output.
In these cases you can mock the -B and -T to your own functions.

    mock_file_check( '-B' => sub { ... } );
    mock_file_check( '-T' => sub { ... } );

=head3 mock_all_from_stat

By using 'mock_all_from_stat' function, you will only provide a 'fake' stat / lstat function and
let Overload::FileCheck provide the hooks for all common checks

# EXAMPLE: examples/mock_all_from_stat.t

=head2 Using stat_as_* helpers

When mocking the stat functions you might consider using one of the 'stat_as_*' helper.
Available functions are:

=over

=item stat_as_directory

=item stat_as_file

=item stat_as_symlink

=item stat_as_socket

=item stat_as_chr

=item stat_as_block

=back


All of these functions take some optional arguments to set: uid, gid, size, atime, mtime, ctime, perms, size.
Example:

    use Overload::FileCheck -from-stat => \&my_stat, q{:check};

    sub my_stat {
        my ( $stat_or_lstat, $f_or_fh ) = @_;

        return stat_as_file() if $f_or_fh eq 'fake.file';

        return stat_as_directory( uid => 0, gid => 'root' ) if $f_or_fh eq 'fake.dir';

        return stat_as_file( mtime => time() ) if $f_or_fh eq 'touch.file';

        return stat_as_file( perms => 0755 ) if $f_or_fh eq 'touch.file.0755';

        return FALLBACK_TO_REAL_OP;
    }


=head1 Available functions

=head2 mock_file_check( $check, CODE )

mock_file_check function is used to mock one of the filecheck op.

The first argument is one of the file check: '-f', '-e', ... where the dash is optional.
It also accepts 'e', 'f', ...

When trying to mock a filecheck already mocked, the function will die with an error like

  -f is already mocked by Overload::FileCheck

This would guarantee that you are not mocking multiple times the same filecheck in your codebase.

Otherwise returns 1 on success.

  # this is probably a very bad idea to do this in your codebase
  # but can be useful for some testing
  # in that sample all '-e' checks will always return true...
  mock_file_check( '-e' => sub { 1 } )

=head2 unmock_file_check( $check, [@extra_checks] )

Disable the effect of one or more specific mock.
The argument to unmock_file_check can be a list or a single scalar value.
The leading dash is optional.

  unmock_file_check( '-e' );
  unmock_file_check( 'e' );            # also work without the dash
  unmock_file_check( qw{-e -f -z} );
  unmock_file_check( qw{e f} );        # also work without the dashes

=head2 unmock_all_file_checks()

By a simple call to unmock_all_file_checks, you would disable the effect of overriding the
filecheck OPs. (not that the XS code is still plugged in, but fallback as soon
as possible to the original OP)

=head2 mock_stat( CODE )

mock_stat provides one interface to setup a hook for all C<stat> and C<lstat> calls.
It's slighly different than the other mock functions. As the first argument passed to
the hook function would be a string 'stat' or 'lstat'.

You can get a more advanced hook sample from L</"Mocking stat">.

    use Overload::FileCheck q(:all);

    # our helper would be called for every stat & lstat calls
    mock_stat( \&my_stat );

    sub my_stat {
        my ( $opname, $file_or_handle ) = @_;

        ...

        return FALLBACK_TO_REAL_OP;
    }


=head2 unmock_stat()

By calling unmock_stat, you would disable any previous hook set using mock_stat


=head2 mock_all_from_stat( CODE )

By providing a single hook for 'stat' and 'lstat' you let OverLoad::FileCheck take care
of mocking all other -X checks.

read L</" Mocking all file checks from a single 'stat' function"> for sample usage.

=head2 stat_as_directory( %OPTS )

Create a stat array ref for a directory.
%OPTS is optional and can set one or more using arguments among: uid, gid, size, atime, mtime, ctime, perms, size.
read the section L</"Using stat_as_* helpers"> for some sample usages.

=head2 stat_as_file( %OPTS )

Create a stat array ref for a regular file
view stat_as_directory and L</"Using stat_as_* helpers"> for some sample usages

=head2 stat_as_symlink( %OPTS )

Create a stat array ref for a symlink
view stat_as_directory and L</"Using stat_as_* helpers"> for some sample usages

=head2 stat_as_socket( %OPTS )

Create a stat array ref for a socket
view stat_as_directory and L</"Using stat_as_* helpers"> for some sample usages

=head2 stat_as_chr( %OPTS )

Create a stat array ref for an empty character device
view stat_as_directory and L</"Using stat_as_* helpers"> for some sample usages

=head2 stat_as_block( %OPTS )

Create a stat array ref for an empty block device
view stat_as_directory and L</"Using stat_as_* helpers"> for some sample usages

=head1 Notice

This is a very early development stage and some behavior might change before the release of a more stable build.

=head1 Known Limitations

=head2 This is design for Unit Test purpose

This code was mainly designed to be used during unit tests. It's far from being optimized at this time.

=head2 Mock as soon as possible

Code loaded/interpreted before mocking a file check, would not take benefit of Overload::FileCheck.
You probably want to load and call the mock function of Overload::FileCheck as early as possible.

=head2 Empty string instead of Undef

Several test operators once mocked will not return the expected 'undef' value but one empty string
instead. This is a future improvement. If you check the output of -X operators in boolean context
it should not impact you.

=head2 -B and -T are using heuristics

File check operators like -B and -T are using heuristics to guess if the file content is binary or text.
By using mock_all_from_stat or ('-from-stat' at import time), we cannot provide an accurate -B or -T checks.
You would need to provide a custom hooks for them

=head1 TODO

=over

=item support for 'undef' using CHECK_IS_UNDEF as valid return (in addition to CHECK_IS_FALSE)

=back

=head1 LICENSE

This software is copyright (c) 2018 by cPanel, Inc.

This is free software; you can redistribute it and/or modify it under the same terms as the Perl 5 programming
language system itself.

=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY
APPLICABLE LAW. EXCEPT WHEN OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES PROVIDE THE
SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE
OF THE SOFTWARE IS WITH YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL NECESSARY SERVICING,
REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY
WHO MAY MODIFY AND/OR REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE LIABLE TO YOU FOR DAMAGES,
INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE THE
SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR
THIRD PARTIES OR A FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF SUCH HOLDER OR OTHER PARTY HAS
BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.

