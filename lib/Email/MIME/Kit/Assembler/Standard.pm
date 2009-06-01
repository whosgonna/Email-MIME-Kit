package Email::MIME::Kit::Assembler::Standard;
use Moose;
use Moose::Util::TypeConstraints;
# ABSTRACT: the standard kit assembler

with 'Email::MIME::Kit::Role::Assembler';

use Email::MIME::Creator;
use Encode ();
use File::Basename;

sub BUILD {
  my ($self) = @_;
  $self->_setup_content_ids;
  $self->_pick_and_set_renderer;
  $self->_build_subassemblies;
}

has parent => (
  is  => 'ro',
  isa => maybe_type(role_type('Email::MIME::Kit::Role::Assembler')),
);

has renderer => (
  reader   => 'renderer',
  writer   => '_set_renderer',
  clearer  => '_unset_renderer',
  isa      => maybe_type(role_type('Email::MIME::Kit::Role::Renderer')),
  init_arg => undef,
);

sub assemble {
  my ($self, $stash) = @_;

  my $manifest = $self->manifest;

  my $has_body = defined $manifest->{body};
  my $has_path = defined $manifest->{path};
  my $has_alts = @{ $manifest->{alternatives} || [] };
  my $has_att  = @{ $manifest->{attachments}  || [] };

  Carp::croak("neither body, path, nor alternatives provided")
    unless $has_body or $has_path or $has_alts;

  Carp::croak("you must provide only one of body, path, or alternatives")
    unless (grep {$_} $has_body, $has_path, $has_alts) == 1;

  my $assembly_method = $has_body ? '_assemble_from_manifest_body'
                      : $has_path ? '_assemble_from_kit'
                      : $has_alts ? '_assemble_mp_alt'
                      :             confess "unreachable code is a mistake";

  $self->$assembly_method($stash);
}

sub _assemble_from_string {
  my ($self, $body, $stash) = @_;

  # I really shouldn't have to do this, but I'm not going to go screw around
  # with @#$@#$ Email::Simple/MIME just to deal with it right now. -- rjbs,
  # 2009-01-19
  $body .= "\x0d\x0a" unless $body =~ /[\x0d|\x0a]\z/;

  my $body_ref = $self->render(\$body, $stash);

  my %attr = %{ $self->manifest->{attributes} || {} };
  $attr{content_type} = $attr{content_type} || 'text/plain';

  if ($$body_ref =~ /[\x80-\xff]/) {
    $attr{encoding} ||= 'quoted-printable';
    $attr{charset}  ||= 'utf-8';
  }

  my $email = $self->_contain_attachments({
    attributes => \%attr,
    header     => $self->manifest->{header},
    stash      => $stash,
    body       => $$body_ref,
    container_type => $self->manifest->{container_type},
  });
}

sub _assemble_from_manifest_body {
  my ($self, $stash) = @_;

  $self->_assemble_from_string(
    $self->manifest->{body},
    $stash,
  );
}

sub _assemble_from_kit {
  my ($self, $stash) = @_;

  my $body_ref = $self->kit->get_kit_entry($self->manifest->{path});

  $self->_assemble_from_string($$body_ref, $stash);
}

sub _assemble_mp_alt {
  my ($self, $stash) = @_;

  my %attr = %{ $self->manifest->{attributes} || {} };
  $attr{content_type} = $attr{content_type} || 'multipart/alternative';

  if ($attr{content_type} !~ qr{\Amultipart/alternative\b}) {
    confess "illegal content_type for mail with alts: $attr{content_type}";
  }

  my $parts = [ map { $_->assemble($stash) } $self->_alternatives ];

  my $email = $self->_contain_attachments({
    attributes => \%attr,
    header     => $self->manifest->{header},
    stash      => $stash,
    parts      => $parts,
  });
}

sub _renderer_from_override {
  my ($self, $override) = @_;
  
  # Allow an explicit undef to mean "no rendering is to be done." -- rjbs,
  # 2009-01-19
  return undef unless defined $override;

  return $self->kit->_build_component(
    'Email::MIME::Kit::Renderer',
    $override,
  );
}

sub _pick_and_set_renderer {
  my ($self)  = @_;

  # "renderer" entry at top-level sets the kit default_renderer, so trying to
  # look at the "renderer" entry at top-level for an override is nonsensical
  # -- rjbs, 2009-01-22
  unless ($self->parent) {
    $self->_set_renderer($self->kit->default_renderer);
    return;
  }

  # If there's no override, we just use the parent.  We don't need to worry
  # about the "there is no parent" case, because that was handled above. --
  # rjbs, 2009-01-22
  unless (exists $self->manifest->{renderer}) {
    $self->_set_renderer($self->parent->renderer);
    return;
  }

  my $renderer = $self->_renderer_from_override($self->manifest->{renderer});
  $self->_set_renderer($renderer);
}

has manifest => (
  is       => 'ro',
  required => 1,
);

has [ qw(_attachments _alternatives) ] => (
  is  => 'ro',
  isa => 'ArrayRef',
  init_arg   => undef,
  default    => sub { [] },
  auto_deref => 1,
);

has _body => (
  reader => 'body',
  writer => '_set_body',
);

sub _build_subassemblies {
  my ($self) = @_;
  
  if (my $body = $self->manifest->{body}) {
    $self->_set_body($body);
  }

  for my $attach (@{ $self->manifest->{attachments} || [] }) {
    my $assembler = $self->kit->_assembler_from_manifest($attach, $self);
    $assembler->_set_attachment_info($attach);
    push @{ $self->_attachments }, $assembler;
  }

  for my $alt (@{ $self->manifest->{alternatives} || [] }) {
    push @{ $self->_alternatives },
      $self->kit->_assembler_from_manifest($alt, $self);
  }
}

sub _set_attachment_info {
  my ($self, $manifest) = @_;

  my $attr = $manifest->{attributes} ||= {};

  $attr->{encoding}    = 'base64' unless exists $attr->{encoding};
  $attr->{disposition} = 'attachment' unless exists $attr->{disposition};

  unless (exists $attr->{filename}) {
    my $filename;
    ($filename) = File::Basename::fileparse($manifest->{path})
      if $manifest->{path};

    # XXX: Steal the attachment-name-generator from Email::MIME::Modifier, or
    # something. -- rjbs, 2009-01-20
    $filename ||= "unknown-attachment";

    $attr->{filename} = $filename;
  }
}

sub render {
  my ($self, $input_ref, $stash) = @_;
  local $stash->{cid_for} = sub { $self->cid_for_path($_[0]) };
  return $input_ref unless my $renderer = $self->renderer;
  return $renderer->render($input_ref, $stash);
}

sub _prep_header {
  my ($self, $header, $stash) = @_;

  my @done_header;
  for my $entry (@$header) {
    confess "no field name candidates"
      unless my (@hval) = grep { /^[^:]/ } keys %$entry;
    confess "multiple field name candidates: @hval" if @hval > 1;
    my $value = $entry->{ $hval[ 0 ] };

    if (ref $value) {
      my ($v, $p) = @$value;
      $value = join q{; }, $v, map { "$_=$p->{$_}" } keys %$p;
    } else {
      # I don't think I need to bother with $self->render, which will set up
      # the cid_for callback.  Honestly, who is going to be referencing a
      # content-id from a header?  Let's hope I never find out... -- rjbs,
      # 2009-01-22
      my $renderer = exists $entry->{':renderer'}
                   ? $self->_renderer_from_override($entry->{':renderer'})
                   : $self->renderer;

      $value = ${ $renderer->render(\$value, $stash) } if defined $renderer;
    }

    {
      use bytes;
      $value = Encode::encode('MIME-Q', $value) if $value =~ /[\x80-\xff]/;
    }
    push @done_header, $hval[0] => $value;
  }

  return \@done_header;
}

sub _contain_attachments {
  my ($self, $arg) = @_;
  
  my @attachments = $self->_attachments;
  my $header = $self->_prep_header($arg->{header}, $arg->{stash});

  my $ct = $arg->{container_type};

  unless (@attachments) {
    confess "container_type given for single-part assembly" if $ct;

    return Email::MIME->create(
      attributes => $arg->{attributes},
      header     => $header,
      body       => $arg->{body},
      parts      => $arg->{parts},
    );
  }

  my $email = Email::MIME->create(
    attributes => $arg->{attributes},
    body       => $arg->{body},
    parts      => $arg->{parts},
  );

  my @att_parts = map { $_->assemble($arg->{stash}) } @attachments;

  my $container = Email::MIME->create(
    attributes => { content_type => ($ct || 'multipart/mixed') },
    header     => $header,
    parts      => [ $email, @att_parts ],
  );

  return $container;
}

has _cid_registry => (
  is       => 'ro',
  init_arg => undef,
  default  => sub { { } },
);

sub cid_for_path {
  my ($self, $path) = @_;
  my $cid = $self->_cid_registry->{ $path };

  confess "no content-id for path $path" unless $cid;

  return $cid;
}

sub _setup_content_ids {
  my ($self) = @_;

  for my $att (@{ $self->manifest->{attachments} || [] }) {
    next unless $att->{path};

    for my $header (@{ $att->{header} }) {
      my ($header) = grep { /^[^:]/ } keys %$header;
      Carp::croak("attachments must not supply content-id")
        if lc $header eq 'content-id';
    }

    my $cid = $self->kit->_generate_content_id;
    push @{ $att->{header} }, {
      'Content-Id' => $cid,
      ':renderer'  => undef,
    };

    $self->_cid_registry->{ $att->{path} } = $cid;
  }
}

no Moose::Util::TypeConstraints;
no Moose;
1;
