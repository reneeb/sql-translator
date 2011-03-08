package SQL::Translator::Producer::SQLServer;

=head1 NAME

SQL::Translator::Producer::SQLServer - MS SQLServer producer for SQL::Translator

=head1 SYNOPSIS

  use SQL::Translator;

  my $t = SQL::Translator->new( parser => '...', producer => 'SQLServer' );
  $t->translate;

=head1 DESCRIPTION

B<WARNING>B This is still fairly early code, basically a hacked version of the
Sybase Producer (thanks Sam, Paul and Ken for doing the real work ;-)

=head1 Extra Attributes

=over 4

=item field.list

List of values for an enum field.

=back

=head1 TODO

 * !! Write some tests !!
 * Reserved words list needs updating to SQLServer.
 * Triggers, Procedures and Views DO NOT WORK

=cut

use strict;
use warnings;
our ( $DEBUG, $WARN );
our $VERSION = '1.59';
$DEBUG = 1 unless defined $DEBUG;

use Data::Dumper;
use SQL::Translator::Schema::Constants;
use SQL::Translator::Utils qw(debug header_comment);
use SQL::Translator::Generator::Utils;
use SQL::Translator::Generator::DDL::SQLServer;

my $util = SQL::Translator::Generator::Utils->new( quote_chars => ['[', ']'] );
my $future = SQL::Translator::Generator::DDL::SQLServer->new();

my %translate  = (
    date      => 'datetime',
    'time'    => 'datetime',
    # Sybase types
    #integer   => 'numeric',
    #int       => 'numeric',
    #number    => 'numeric',
    #money     => 'money',
    #varchar   => 'varchar',
    #varchar2  => 'varchar',
    #timestamp => 'datetime',
    #text      => 'varchar',
    #real      => 'double precision',
    #comment   => 'text',
    #bit       => 'bit',
    #tinyint   => 'smallint',
    #float     => 'double precision',
    #serial    => 'numeric',
    #boolean   => 'varchar',
    #char      => 'char',
    #long      => 'varchar',
);

# If these datatypes have size appended the sql fails.
my @no_size = qw/tinyint smallint int integer bigint text bit image datetime/;

my $max_id_length    = 128;
my %global_names;

=pod

=head1 SQLServer Create Table Syntax

TODO

=cut

sub produce {
    my $translator     = shift;
    $DEBUG             = $translator->debug;
    $WARN              = $translator->show_warnings;
    my $no_comments    = $translator->no_comments;
    my $add_drop_table = $translator->add_drop_table;
    my $schema         = $translator->schema;

    %global_names = (); #reset

    my $output;
    $output .= header_comment."\n" unless ($no_comments);

    # Generate the DROP statements.
    if ($add_drop_table) {
        my @tables = sort { $b->order <=> $a->order } $schema->get_tables;
        $output .= "--\n-- Turn off constraints\n--\n\n" unless $no_comments;
        foreach my $table (@tables) {
            my $name = $table->name;
            my $q_name = unreserve($name);
            $output .= "IF EXISTS (SELECT name FROM sysobjects WHERE name = '$name' AND type = 'U') ALTER TABLE $q_name NOCHECK CONSTRAINT all;\n"
        }
        $output .= "\n";
        $output .= "--\n-- Drop tables\n--\n\n" unless $no_comments;
        foreach my $table (@tables) {
            my $name = $table->name;
            my $q_name = unreserve($name);
            $output .= "IF EXISTS (SELECT name FROM sysobjects WHERE name = '$name' AND type = 'U') DROP TABLE $q_name;\n"
        }
    }

    # Generate the CREATE sql

    my @foreign_constraints = (); # these need to be added separately, as tables may not exist yet

    for my $table ( $schema->get_tables ) {
        my $table_name    = $table->name or next;
        my $table_name_ur = unreserve($table_name) || '';

        my ( @comments, @field_defs, @index_defs, @constraint_defs );

        push @comments, "\n\n--\n-- Table: $table_name_ur\n--"
        unless $no_comments;

        push @comments, map { "-- $_" } $table->comments;

        #
        # Fields
        #
        my %field_name_scope;
        for my $field ( $table->get_fields ) {
            my $field_name    = $field->name;

            #
            # Datatype
            #
            my $data_type      = lc $field->data_type;
            my %extra          = $field->extra;
            my $list           = $extra{'list'} || [];
            # \todo deal with embedded quotes
            my $commalist      = join( ', ', map { qq['$_'] } @$list );

            if ( $data_type eq 'enum' ) {
                my $check_name = mk_name( $field_name . '_chk' );
                push @constraint_defs,
                  "CONSTRAINT $check_name CHECK ($field_name IN ($commalist))";
                $data_type .= 'character varying';
            }

            push @field_defs, $future->field($field);
        }

        #
        # Constraint Declarations
        #
        my @constraint_decs = ();
        for my $constraint ( $table->get_constraints ) {
            my $type    = $constraint->type || NORMAL;
            next unless $constraint->fields;

            my $c_def;
            if ( $type eq FOREIGN_KEY ) {
                push @foreign_constraints, $future->foreign_key_constraint($constraint);
                next;
            }


            if ( $type eq PRIMARY_KEY ) {
                $c_def = $future->primary_key_constraint($constraint)
            }
            elsif ( $type eq UNIQUE ) {
                if (!grep { $_->is_nullable } $constraint->fields) {
                  $c_def = $future->unique_constraint_single($constraint)
                } else {
                   push @index_defs, $future->unique_constraint_multiple($constraint);
                   next;
                }
            }
            push @constraint_defs, $c_def;
        }

        #
        # Indices
        #
        for my $index ( $table->get_indices ) {
            push @index_defs, $future->index($index)
        }

        my $create_statement = "";
        $create_statement .= qq[CREATE TABLE $table_name_ur (\n].
            join( ",\n",
                map { "  $_" } @field_defs, @constraint_defs
            ).
            "\n);"
        ;

        $output .= join( "\n\n",
            @comments,
            $create_statement,
            @index_defs,
        );
    }

# Add FK constraints
    $output .= join ("\n", '', @foreign_constraints) if @foreign_constraints;

# create view/procedure are NOT prepended to the input $sql, needs
# to be filled in with the proper syntax

=pod

    # Text of view is already a 'create view' statement so no need to
    # be fancy
    foreach ( $schema->get_views ) {
        my $name = $_->name();
        $output .= "\n\n";
        $output .= "--\n-- View: $name\n--\n\n" unless $no_comments;
        my $text = $_->sql();
        $text =~ s/\r//g;
        $output .= "$text\nGO\n";
    }

    # Text of procedure already has the 'create procedure' stuff
    # so there is no need to do anything fancy. However, we should
    # think about doing fancy stuff with granting permissions and
    # so on.
    foreach ( $schema->get_procedures ) {
        my $name = $_->name();
        $output .= "\n\n";
        $output .= "--\n-- Procedure: $name\n--\n\n" unless $no_comments;
        my $text = $_->sql();
      $text =~ s/\r//g;
        $output .= "$text\nGO\n";
    }
=cut

    return $output;
}

sub mk_name {
    my ($name, $scope, $critical) = @_;

    $scope ||= \%global_names;
    if ( my $prev = $scope->{ $name } ) {
        my $name_orig = $name;
        $name        .= sprintf( "%02d", ++$prev );
        substr($name, $max_id_length - 3) = "00"
            if length( $name ) > $max_id_length;

        warn "The name '$name_orig' has been changed to ",
             "'$name' to make it unique.\n" if $WARN;

        $scope->{ $name_orig }++;
    }
    $name = substr( $name, 0, $max_id_length )
                        if ((length( $name ) > $max_id_length) && $critical);
    $scope->{ $name }++;
    return unreserve($name);
}

sub unreserve { $util->quote($_[0]) }

1;

=pod

=head1 SEE ALSO

SQL::Translator.

=head1 AUTHORS

Mark Addison E<lt>grommit@users.sourceforge.netE<gt> - Bulk of code from
Sybase producer, I just tweaked it for SQLServer. Thanks.

=cut
