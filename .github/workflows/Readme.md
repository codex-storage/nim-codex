Tips for shorter build times
----------------------------

### Runner availability ###

When running on the Github free, pro or team plan, the bottleneck when
optimizing workflows is the availability of macOS runners. Therefore, anything
that reduces the time spent in macOS jobs will have a positive impact on the
time waiting for runners to become available. On the Github enterprise plan,
this is not the case and you can more freely use parallelization on multiple
runners. The usage limits for Github Actions are [described here][limits]. You
can see a breakdown of runner usage for your jobs in the Github Actions tab
([example][usage]).

### Windows is slow ###

Performing git operations and compilation are both slow on Windows. This can
easily mean that a Windows job takes twice as long as a Linux job. Therefore it
makes sense to use a Windows runner only for testing Windows compatibility, and
nothing else. Testing compatibility with other versions of Nim, code coverage
analysis, etc. are therefore better performed on a Linux runner.

### Parallelization ###

Breaking up a long build job into several jobs that you run in parallel can have
a positive impact on the wall clock time that a workflow runs. For instance, you
might consider running unit tests and integration tests in parallel. When
running on the Github free, pro or team plan, keep in mind that availability of
macOS runners is a bottleneck. If you split a macOS job into two jobs, you now
need to wait for two macOS runners to become available.

### Refactoring ###

As with any code, complex workflows are hard to read and change. You can use
[composite actions][composite] and [reusable workflows][reusable] to refactor
complex workflows.

### Steps for measuring time

Breaking up steps allows you to see the time spent in each part. For instance,
instead of having one step where all tests are performed, you might consider
having separate steps for e.g. unit tests and integration tests, so that you can
see how much time is spent in each.

### Fix slow tests ###

Try to avoid slow unit tests. They not only slow down continuous integration,
but also local development. If you encounter slow tests you can consider
reworking them to stub out the slow parts that are not under test, or use
smaller data structures for the test.

You can use [unittest2][unittest2] together with the environment variable
`NIMTEST_TIMING=true` to show how much time is spent in every test
([reference][testtime]).

### Caching ###

Ensure that caches are updated over time. For instance if you cache the latest
version of the Nim compiler, then you want to update the cache when a new
version of the compiler is released. See also the documentation
for the [cache action][cache].

### Fail fast ###

By default a workflow fails fast: if one job fails, the rest are cancelled. This
might seem inconvenient, because when you're debugging an issue you often want
to know whether you introduced a failure on all platforms, or only on a single
one. You might be tempted to disable fail-fast, but keep in mind that this keeps
runners busy for longer on a workflow that you know is going to fail anyway.
Consequent runs will therefore take longer to start. Fail fast is most likely
better for overall development speed.

[usage]: https://github.com/logos-storage/logos-storage-nim/actions/runs/3462031231/usage
[composite]: https://docs.github.com/en/actions/creating-actions/creating-a-composite-action
[reusable]: https://docs.github.com/en/actions/using-workflows/reusing-workflows
[cache]: https://github.com/actions/cache/blob/main/workarounds.md#update-a-cache
[unittest2]: https://github.com/status-im/nim-unittest2
[testtime]: https://github.com/status-im/nim-unittest2/pull/12
[limits]: https://docs.github.com/en/actions/learn-github-actions/usage-limits-billing-and-administration#usage-limits
