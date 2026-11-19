/// Tests of the order API (2019 web project). They run against the seeded demo data
/// (scripts/reset.sh).
Class OM.Test.OrderAPI Extends %UnitTest.TestCase
{

Method TestGetOrder()
{
    set o = ##class(OM.API.Order).Get(1)
    do $$$AssertTrue($isobject(o), "order 1 exists")
    do $$$AssertTrue(o.lines.%Size() >= 1, "order 1 has lines")
    do $$$AssertEquals(o.customer, +$piece(^SORD(1), "^", 1))
}

Method TestGetMissingOrder()
{
    do $$$AssertEquals(##class(OM.API.Order).Get(999999), "")
}

Method TestListByCustomer()
{
    set cid = +^SORD(1)
    set n = 0, o = ""
    for {
        set o = $order(^SORDX("C", cid, o))
        quit:o=""
        set n = n + 1
    }
    set list = ##class(OM.API.Order).ListByCustomer(cid)
    do $$$AssertEquals(list.%Size(), n, "one entry per order of the customer")
    do $$$AssertTrue(list.%Get(0).id > list.%Get(list.%Size() - 1).id, "newest first")
}

}
