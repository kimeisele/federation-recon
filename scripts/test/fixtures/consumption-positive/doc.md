# Consumption Test Fixture

The Finding ID below is deliberately on a line that does NOT contain the
repository slug. Otherwise the slug pattern alone matches the line, the Finding
ID appears in the output as a side effect, and the positive control passes even
when the Finding-ID pattern is broken — which is precisely the defect this
fixture exists to detect.

Cited Finding: finding-0fc027b8a436

That is the only line the Finding-ID pattern should match.
