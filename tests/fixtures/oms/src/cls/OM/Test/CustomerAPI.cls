/// Tests of the customer API (2019 web project). They run against the seeded demo data
/// (scripts/reset.sh), in which customer 1 is "SMITH, JONES & CO".
Class OM.Test.CustomerAPI Extends %UnitTest.TestCase
{

Method TestGetKnownCustomer()
{
    set c = ##class(OM.API.Customer).Get(1)
    do $$$AssertTrue($isobject(c), "customer 1 exists")
    do $$$AssertEquals(c.name, "SMITH, JONES & CO")
    do $$$AssertEquals(c.country, $piece(^CUST(1), "^", 2))
}

Method TestGetMissingCustomer()
{
    do $$$AssertEquals(##class(OM.API.Customer).Get(999999), "")
}

Method TestList()
{
    set list = ##class(OM.API.Customer).List(5)
    do $$$AssertEquals(list.%Size(), 5)
    do $$$AssertEquals(list.%Get(0).id, $order(^CUST("")), "lowest id first")
    do $$$AssertEquals(list.%Get(0).name, $piece(^CUST($order(^CUST(""))), "^", 1))
}

Method TestFindByPrefix()
{
    set list = ##class(OM.API.Customer).Find("SMITH, J")
    do $$$AssertTrue(list.%Size() >= 1, "at least one SMITH, J... customer")
    do $$$AssertEquals(list.%Get(0).id, 1)
}

Method TestCreateAndGet()
{
    set id = ##class(OM.API.Customer).Create("Unit Test Customer", "GB", 1000)
    do $$$AssertTrue(id > 0, "new customer id")
    set c = ##class(OM.API.Customer).Get(id)
    do $$$AssertEquals(c.name, "UNIT TEST CUSTOMER")
    do $$$AssertEquals(c.creditLimit, 1000)
    // clean up by hand, leaving no trace in the data or the indexes
    kill ^CUST(id), ^CUSTX("N", "UNIT TEST CUSTOMER", id), ^CUSTX("C", "GB", id)
}

}
