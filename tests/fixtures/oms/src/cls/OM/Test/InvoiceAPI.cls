/// Tests of the invoice API used by the web UI. They run against the seeded demo data
/// (scripts/reset.sh) and work out what to expect from the globals, not from fixed values.
Class OM.Test.InvoiceAPI Extends %UnitTest.TestCase
{

Method TestGetInvoice()
{
    set inv = $order(^INVC(""), 1, rec)
    do $$$AssertNotEquals(inv, "", "the seed has invoices")
    set i = ##class(OM.API.Invoice).Get(inv)
    do $$$AssertEquals(i.id, inv)
    do $$$AssertEquals(i.order, $piece(rec, "^", 1))
    do $$$AssertEquals(i.customer, $piece(rec, "^", 2))
    do $$$AssertEquals(i.amount, +$piece(rec, "^", 4))
    do $$$AssertEquals(i.outstanding, $piece(rec, "^", 4) - $piece(rec, "^", 6))
    do $$$AssertEquals(i.status, $piece(rec, "^", 7))
}

Method TestGetMissingInvoice()
{
    do $$$AssertEquals(##class(OM.API.Invoice).Get(999999), "")
}

Method TestListByCustomer()
{
    set cust = $order(^INVCX("C", ""))
    set n = 0, inv = ""
    for {
        set inv = $order(^INVCX("C", cust, inv))
        quit:inv=""
        set n = n + 1
    }
    set list = ##class(OM.API.Invoice).ListByCustomer(cust)
    do $$$AssertEquals(list.%Size(), n, "one entry per invoice in the customer index")
    do $$$AssertEquals(list.%Get(0).id, $order(^INVCX("C", cust, ""), -1), "newest first")
    do $$$AssertEquals(list.%Get(0).customer, cust)
}

}
