package Minion::Backend::mysql;

use 5.010;

use Mojo::Base 'Minion::Backend';

use Mojo::IOLoop;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::mysql;
use Sys::Hostname 'hostname';

has 'mysql';

our $VERSION = '0.12';

sub dequeue {
  my ($self, $id, $wait, $options) = @_;

  if ((my $job = $self->_try($id, $options))) { return $job }
  return undef if Mojo::IOLoop->is_running;

  my $cb = $self->mysql->pubsub->listen("minion.job" => sub {
    Mojo::IOLoop->stop;
  });

  my $timer = Mojo::IOLoop->timer($wait => sub { Mojo::IOLoop->stop });
  Mojo::IOLoop->start;

  $self->mysql->pubsub->unlisten("minion.job" => $cb) and Mojo::IOLoop->remove($timer);

  return $self->_try($id, $options);
}

sub enqueue {
  my ($self, $task) = (shift, shift);
  my $args    = shift // [];
  my $options = shift // {};

  my $db = $self->mysql->db;

  my $seconds = $db->dbh->quote($options->{delay} // 0);
  $db->query(
    "insert into minion_jobs (`args`, `attempts`, `delayed`, `priority`, `queue`, `task`)
     values (?, ?, (DATE_ADD(NOW(), INTERVAL $seconds SECOND)), ?, ?, ?)",
     encode_json($args), $options->{attempts} // 1,
     $options->{priority} // 0, $options->{queue} // 'default', $task
  );
  my $job_id = $db->dbh->{mysql_insertid};

  $self->mysql->pubsub->notify("minion.job" => $job_id);

  return $job_id;
}

sub fail_job   { shift->_update(1, @_) }
sub finish_job { shift->_update(0, @_) }

sub list_jobs {
  my ($self, $offset, $limit, $options) = @_;

  my ( @where, @params );
  if ( my $state = $options->{state} ) {
    my @states = ref $state eq 'ARRAY' ? @$state : ( $state );
    push @where, 'state in (' . join( ',', ('?') x @states ) . ')';
    push @params, @states;
  }
  if ( my $task = $options->{task} ) {
    my @tasks = ref $task eq 'ARRAY' ? @$task : ( $task );
    push @where, 'task in (' . join( ',', ('?') x @tasks ) . ')';
    push @params, @tasks;
  }
  if ( my $id = $options->{ids} ) {
    my @ids = ref $id eq 'ARRAY' ? @$id : ( $id );
    push @where, 'id in (' . join( ',', ('?') x @ids ) . ')';
    push @params, @ids;
  }

  my $where = @where ? 'WHERE ' . join( ' AND ', @where ) : '';
  # XXX: notes column missing
  my $jobs = $self->mysql->db->query(
    "SELECT
      id, args, attempts,
      UNIX_TIMESTAMP(created) AS created,
      UNIX_TIMESTAMP(`delayed`) AS `delayed`,
      UNIX_TIMESTAMP(finished) AS finished, priority,
      queue, result, UNIX_TIMESTAMP(retried) AS retried, retries,
      UNIX_TIMESTAMP(started) AS started, state, task,
      worker
    FROM minion_jobs
    $where
    ORDER BY id DESC
    LIMIT ?
    OFFSET ?", @params, $limit, $offset,
  )->hashes;
  $jobs->map( _decode_json_fields(qw{ args result }) )
    # XXX: Job children/parents not supported
    # Add fake arrayrefs to make the Minion UI work
    ->map( sub { $_[0]->{parents} = $_[0]->{children} = []; return $_[0] } );

  my $total = $self->mysql->db->query(
    'SELECT COUNT(*) AS count FROM minion_jobs',
  )->hash->{count};

  return {
    jobs => $jobs,
    total => $total,
  }
}

sub _decode_json_fields {
  my @fields = @_;
  return sub {
    my $hash = shift;
    for my $field ( @fields ) {
      next unless $hash->{ $field };
      $hash->{ $field } = decode_json( $hash->{ $field } );
    }
    return $hash;
  };
}

sub list_workers {
  my ($self, $offset, $limit, $options) = @_;

  my ( @where, @params );
  if ( my $ids = $options->{ids} ) {
    push @where, 'id in (' . join( ',', ('?') x @{$options->{ids}} ) . ')';
    push @params, @{ $options->{ids} };
  }

  my $where = @where ? 'WHERE ' . join ' AND ', @where : '';
  # XXX: Missing "status" column for workers
  my $sql = "SELECT
    id, UNIX_TIMESTAMP(notified) AS notified, host, pid,
    UNIX_TIMESTAMP(started) AS started
  FROM minion_workers $where ORDER BY id DESC LIMIT ? OFFSET ?";
  my $workers = $self->mysql->db->query($sql, @params, $limit, $offset)
    ->hashes;

  # Add jobs to each worker
  my $jobs_sql = q{SELECT id FROM minion_jobs WHERE state='active' AND worker=?};
  $workers->map( sub {
      $_->{jobs} = $self->mysql->db->query($jobs_sql, $_->{id})->arrays->flatten->to_array
  } );

  my $total = $self->mysql->db->query(
    'SELECT COUNT(*) AS count FROM minion_workers',
  )->hash->{count};

  return {
    workers => $workers,
    total => $total,
  };
}

sub new {
  my ( $class, @args ) = @_;
  if ( ref $args[0] eq 'HASH' ) {
    @args = %{ $args[0] };
  }
  my $self = $class->SUPER::new(mysql => Mojo::mysql->new(@args));
  my $mysql = $self->mysql->max_connections(1);
  $mysql->migrations->name('minion')->from_data;
  $mysql->once(connection => sub { shift->migrations->migrate });
  return $self;
}

sub register_worker {
  my ($self, $id) = @_;

  ### TODO: is this the same business logic?
  if ($id) {
      my $sql
        = 'update minion_workers set notified = now() where id = ?';
      return $id if $self->mysql->db->query($sql, $id)->{affected_rows};
  }

  my $db = $self->mysql->db;
  my $sql = 'insert into minion_workers (host, pid) values (?, ?)';
  $db->query($sql, hostname, $$);

  return $db->dbh->{mysql_insertid};
}

sub remove_job {
  !!shift->mysql->db->query(
    "delete from minion_jobs
     where id = ? and state in ('inactive', 'failed', 'finished')",
     shift
  )->{affected_rows};
}

sub repair {
  my $self = shift;

  # Check worker registry
  my $db     = $self->mysql->db;
  my $minion = $self->minion;
  $db->query(
    "delete from minion_workers
     where notified < (DATE_ADD(NOW(), INTERVAL ? SECOND))", $minion->missing_after
  );

  # Abandoned jobs
  $db->query(
    "update minion_jobs as j
     set finished = now(), result = ?,
       state = 'failed'
     where state = 'active'
       and not exists(select 1 from minion_workers where id = j.worker)",
   encode_json('Worker went away')
  );

  # Old jobs
  $db->query(
    "delete from minion_jobs
     where state = 'finished' and finished < (DATE_SUB(NOW(), INTERVAL ? SECOND))",
    $minion->remove_after
  );
}

sub reset {
    my $self = shift;

    $self->mysql->db->query("truncate table minion_jobs");
    $self->mysql->db->query("truncate table minion_workers");
}

sub retry_job {
  my ($self, $id, $retries) = (shift, shift, shift);
  my $options = shift // {};

  my $seconds = $self->mysql->db->dbh->quote($options->{delay} // 0);

  return !!$self->mysql->db->query(
    "update `minion_jobs`
     set `finished` = null, priority = coalesce(?, priority),
      `queue` = coalesce(?, queue), `result` = null, `retried` = now(),
       `retries` = retries + 1, `started` = null, `state` = 'inactive',
       `worker` = null, `delayed` = (DATE_ADD(NOW(), INTERVAL $seconds SECOND))
     where `id` = ? and retries = ? and `state` in ('failed', 'finished')",
     @$options{qw(priority queue)}, $id, $retries
  )->{affected_rows};
}

sub stats {
  my $self = shift;

  my $db  = $self->mysql->db;
  my $all = $db->query('select count(*) from minion_workers')->array->[0];
  my $sql
    = "select count(distinct worker) from minion_jobs where state = 'active'";
  my $active = $db->query($sql)->array->[0];

  #### TODO: odd $a and $b weren't working, or something
  $sql = 'select state, count(state) from minion_jobs group by 1';
  my $results
    = $db->query($sql); # ->reduce(sub { $a->{$b->[0]} = $b->[1]; $a }, {});

  my $states = {};
  while (my $next = $results->array) {
    $states->{$next->[0]} = $next->[1];
  }

  my $uptime = $db->query( 'SHOW GLOBAL STATUS LIKE "Uptime"' )->hash->{Value};

  return {
    active_workers   => $active,
    inactive_workers => $all - $active,
    active_jobs      => $states->{active} || 0,
    inactive_jobs    => $states->{inactive} || 0,
    failed_jobs      => $states->{failed} || 0,
    finished_jobs    => $states->{finished} || 0,
    uptime           => $uptime || 0,
  };
}

sub unregister_worker {
  shift->mysql->db->query('delete from minion_workers where id = ?', shift);
}

sub _try {
  my ($self, $id, $options) = @_;

  my $tasks = [keys %{$self->minion->tasks}];

  return  unless @$tasks;

  my $qq = join(", ", map({ "?" } @{ $options->{queues} // ['default'] }));
  my $qt = join(", ", map({ "?" } @{ $tasks }));

  my $db = $self->mysql->db;

  my $tx = $db->begin;
  my $job = $tx->db->query(qq(select id, args, retries, task from minion_jobs
    where state = 'inactive' and `delayed` <= NOW() and queue in ($qq)
    and task in ($qt)
    order by priority desc, created limit 1 for update),
   @{ $options->{queues} || ['default']}, @{ $tasks }
  )->hash;

  return undef unless $job;

  $tx->db->query(
     qq(update minion_jobs set started = now(), state = 'active', worker = ? where id = ?),
     $id, $job->{id}
  );
  $tx->commit;

  $job->{args} = $job->{args} ? decode_json($job->{args}) : undef;

  $job;
}

sub _update {
  my ($self, $fail, $id, $retries, $result) = @_;
  return undef unless $self->mysql->db->query(
    "update minion_jobs
     set finished = now(), result = ?, state = ?
     where id = ? and retries = ? and state = 'active'",
     encode_json($result), $fail ? 'failed' : 'finished', $id,
    $retries
  )->{affected_rows};
  my $job = $self->list_jobs( 0, 1, { ids => [$id] } )->{jobs}[0];
  return 1 if !$fail || (my $attempts = $job->{attempts}) == 1;
  return 1 if $retries >= ( $attempts - 1 );
  my $delay = $self->minion->backoff->( $retries );
  return $self->retry_job( $id, $retries, { delay => $delay } );
}

sub broadcast {
  my ($self, $command, $args, $ids) = (shift, shift, shift || [], shift || []);
  my $message = encode_json( [ $command, @$args ] );
  if ( !@$ids ) {
    @$ids = map { $_->{id} }
      @{ $self->mysql->db->query( 'SELECT id FROM minion_workers' )->hashes },
  }
  my $rows = 0;
  for my $id ( @$ids ) {
    $rows += $self->mysql->db->query(
      'INSERT INTO minion_workers_inbox ( worker_id, message ) VALUES ( ?, ? )',
      $id, $message,
    )->rows;
  }
  return $rows;
}

sub receive {
  my ($self, $worker_id) = @_;
  #; use Data::Dumper;
  my $rows = $self->mysql->db->query(
    'SELECT id, message FROM minion_workers_inbox WHERE worker_id=?', $worker_id,
  )->hashes;
  return [] unless $rows && @$rows;
  #; say Dumper $rows;
  my @ids = map { $_->{id} } @$rows;
  #; say Dumper \@ids;
  $self->mysql->db->query(
    'DELETE FROM minion_workers_inbox WHERE id IN (' . ( join ", ", ( '?' ) x @ids ) . ')',
    @ids,
  );
  return [ map { decode_json( $_->{message} ) } @$rows ];
}

1;

=encoding utf8

=head1 NAME

Minion::Backend::mysql - MySQL backend

=head1 SYNOPSIS

  use Mojolicious::Lite;

  plugin Minion => {mysql => 'mysql://user@127.0.0.1/minion_jobs'};

  # Slow task
  app->minion->add_task(poke_mojo => sub {
    my $job = shift;
    $job->app->ua->get('mojolicio.us');
    $job->app->log->debug('We have poked mojolicio.us for a visitor');
  });

  # Perform job in a background worker process
  get '/' => sub {
    my $c = shift;
    $c->minion->enqueue('poke_mojo');
    $c->render(text => 'We will poke mojolicio.us for you soon.');
  };

  app->start;

=head1 DESCRIPTION

L<Minion::Backend::mysql> is a backend for L<Minion> based on L<Mojo::mysql>. All
necessary tables will be created automatically with a set of migrations named
C<minion>. This backend requires at least v5.6.5 of MySQL.

=head1 ATTRIBUTES

L<Minion::Backend::mysql> inherits all attributes from L<Minion::Backend> and
implements the following new ones.

=head2 mysql

  my $mysql   = $backend->mysql;
  $backend = $backend->mysql(Mojo::mysql->new);

L<Mojo::mysql> object used to store all data.

=head1 METHODS

L<Minion::Backend::mysql> inherits all methods from L<Minion::Backend> and
implements the following new ones.

=head2 dequeue

  my $job_info = $backend->dequeue($worker_id, 0.5);
  my $job_info = $backend->dequeue($worker_id, 0.5, {queues => ['important']});

Wait for job, dequeue it and transition from C<inactive> to C<active> state or
return C<undef> if queues were empty.

These options are currently available:

=over 2

=item queues

  queues => ['important']

One or more queues to dequeue jobs from, defaults to C<default>.

=back

These fields are currently available:

=over 2

=item args

  args => ['foo', 'bar']

Job arguments.

=item id

  id => '10023'

Job ID.

=item retries

  retries => 3

Number of times job has been retried.

=item task

  task => 'foo'

Task name.

=back

=head2 enqueue

  my $job_id = $backend->enqueue('foo');
  my $job_id = $backend->enqueue(foo => [@args]);
  my $job_id = $backend->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state.

These options are currently available:

=over 2

=item delay

  delay => 10

Delay job for this many seconds (from now).

=item priority

  priority => 5

Job priority, defaults to C<0>.

=item queue

  queue => 'important'

Queue to put job in, defaults to C<default>.

=back

=head2 fail_job

  my $bool = $backend->fail_job($job_id, $retries);
  my $bool = $backend->fail_job($job_id, $retries, 'Something went wrong!');
  my $bool = $backend->fail_job(
    $job_id, $retries, {msg => 'Something went wrong!'});

Transition from C<active> to C<failed> state.

=head2 finish_job

  my $bool = $backend->finish_job($job_id, $retries);
  my $bool = $backend->finish_job($job_id, $retries, 'All went well!');
  my $bool = $backend->finish_job($job_id, $retries, {msg => 'All went well!'});

Transition from C<active> to C<finished> state.

=head2 job_info

  my $job_info = $backend->job_info($job_id);

Get information about a job or return C<undef> if job does not exist.

  # Check job state
  my $state = $backend->job_info($job_id)->{state};

  # Get job result
  my $result = $backend->job_info($job_id)->{result};

These fields are currently available:

=over 2

=item args

  args => ['foo', 'bar']

Job arguments.

=item created

  created => 784111777

Time job was created.

=item delayed

  delayed => 784111777

Time job was delayed to.

=item finished

  finished => 784111777

Time job was finished.

=item priority

  priority => 3

Job priority.

=item queue

  queue => 'important'

Queue name.

=item result

  result => 'All went well!'

Job result.

=item retried

  retried => 784111777

Time job has been retried.

=item retries

  retries => 3

Number of times job has been retried.

=item started

  started => 784111777

Time job was started.

=item state

  state => 'inactive'

Current job state, usually C<active>, C<failed>, C<finished> or C<inactive>.

=item task

  task => 'foo'

Task name.

=item worker

  worker => '154'

Id of worker that is processing the job.

=back

=head2 list_jobs

  my $batch = $backend->list_jobs($offset, $limit);
  my $batch = $backend->list_jobs($offset, $limit, {state => 'inactive'});

Returns the same information as L</"job_info"> but in batches.

These options are currently available:

=over 2

=item state

  state => 'inactive'

List only jobs in this state.

=item task

  task => 'test'

List only jobs for this task.

=back

=head2 list_workers

  my $batch = $backend->list_workers($offset, $limit);

Returns the same information as L</"worker_info"> but in batches.

=head2 new

  my $backend = Minion::Backend::mysql->new('mysql://mysql@/test');

Construct a new L<Minion::Backend::mysql> object.

=head2 register_worker

  my $worker_id = $backend->register_worker;
  my $worker_id = $backend->register_worker($worker_id);

Register worker or send heartbeat to show that this worker is still alive.

=head2 remove_job

  my $bool = $backend->remove_job($job_id);

Remove C<failed>, C<finished> or C<inactive> job from queue.

=head2 repair

  $backend->repair;

Repair worker registry and job queue if necessary.

=head2 reset

  $backend->reset;

Reset job queue.

=head2 retry_job

  my $bool = $backend->retry_job($job_id, $retries);
  my $bool = $backend->retry_job($job_id, $retries, {delay => 10});

Transition from C<failed> or C<finished> state back to C<inactive>.

These options are currently available:

=over 2

=item delay

  delay => 10

Delay job for this many seconds (from now).

=item priority

  priority => 5

Job priority.

=item queue

  queue => 'important'

Queue to put job in.

=back

=head2 stats

  my $stats = $backend->stats;

Get statistics for jobs and workers.

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker.

=head2 worker_info

  my $worker_info = $backend->worker_info($worker_id);

Get information about a worker or return C<undef> if worker does not exist.

  # Check worker host
  my $host = $backend->worker_info($worker_id)->{host};

These fields are currently available:

=over 2

=item host

  host => 'localhost'

Worker host.

=item jobs

  jobs => ['10023', '10024', '10025', '10029']

Ids of jobs the worker is currently processing.

=item notified

  notified => 784111777

Last time worker sent a heartbeat.

=item pid

  pid => 12345

Process id of worker.

=item started

  started => 784111777

Time worker was started.

=back

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut

__DATA__

@@ minion
-- 1 up
create table if not exists minion_jobs (
		`id`       serial not null primary key,
		`args`     mediumblob not null,
		`created`  timestamp not null default current_timestamp,
		`delayed`  timestamp not null default current_timestamp,
		`finished` timestamp null,
		`priority` int not null,
		`result`   mediumblob,
		`retried`  timestamp null,
		`retries`  int not null default 0,
		`started`  timestamp null,
		`state`    varchar(128) not null default 'inactive',
		`task`     text not null,
		`worker`   bigint
);

create table if not exists minion_workers (
		`id`      serial not null primary key,
		`host`    text not null,
		`pid`     int not null,
		`started` timestamp not null default current_timestamp,
		`notified` timestamp not null default current_timestamp
);

-- 1 down
drop table if exists minion_jobs;
drop table if exists minion_workers;

-- 2 up
create index minion_jobs_state_idx on minion_jobs (state);

-- 3 up
alter table minion_jobs add queue varchar(128) not null default 'default';

-- 4 up
ALTER TABLE minion_workers MODIFY COLUMN started timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE minion_workers MODIFY COLUMN notified timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP;
CREATE TABLE IF NOT EXISTS minion_workers_inbox (
  `id` SERIAL NOT NULL PRIMARY KEY,
  `worker_id` BIGINT UNSIGNED NOT NULL,
  `message` BLOB NOT NULL
);
ALTER TABLE minion_jobs ADD COLUMN attempts INT NOT NULL DEFAULT 1;

-- 5 up
ALTER TABLE minion_jobs MODIFY COLUMN args MEDIUMBLOB NOT NULL;
ALTER TABLE minion_jobs MODIFY COLUMN result MEDIUMBLOB;

