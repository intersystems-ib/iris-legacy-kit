/// JSON API for the web UI (ui/), web application /api/oms. Read-only: customers with their
/// orders and invoices, and orders by date. Everything goes through the OM.API classes.
Class OM.REST.Dispatch Extends %CSP.REST
{

Parameter CHARSET = "utf-8";

Parameter CONTENTTYPE = "application/json";

XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
<Route Url="/customers" Method="GET" Call="Customers"/>
<Route Url="/customers/:id" Method="GET" Call="Customer"/>
<Route Url="/orders" Method="GET" Call="Orders"/>
<Route Url="/orders/:id" Method="GET" Call="Order"/>
</Routes>
}

/// GET /customers?name=PREFIX: customers whose name starts with PREFIX; without it, the first 50.
ClassMethod Customers() As %Status
{
    set name = $get(%request.Data("name", 1))
    if name = "" {
        quit ..Reply(##class(OM.API.Customer).List(50))
    }
    quit ..Reply(##class(OM.API.Customer).Find(name))
}

/// GET /customers/:id: the customer with its orders (newest first) and invoices.
ClassMethod Customer(id As %String) As %Status
{
    set obj = ##class(OM.API.Customer).Get(id)
    quit:obj="" ..NotFound("customer", id)
    set obj.orders = ##class(OM.API.Order).ListByCustomer(id)
    set obj.invoices = ##class(OM.API.Invoice).ListByCustomer(id)
    quit ..Reply(obj)
}

/// GET /orders?from=YYYY-MM-DD&to=YYYY-MM-DD: orders dated in the range.
ClassMethod Orders() As %Status
{
    set from = $get(%request.Data("from", 1)), to = $get(%request.Data("to", 1))
    if ($zdateh(from, 3, , , , , , , "") = "") || ($zdateh(to, 3, , , , , , , "") = "") {
        quit ..Fail(400, "from and to must be dates as YYYY-MM-DD")
    }
    set list = ##class(OM.API.Order).ListByDate(from, to)
    set iter = list.%GetIterator()
    while iter.%GetNext(, .ord) {
        do ..AddCustomerName(ord)
    }
    quit ..Reply(list)
}

/// GET /orders/:id: the order with its lines.
ClassMethod Order(id As %String) As %Status
{
    set obj = ##class(OM.API.Order).Get(id)
    quit:obj="" ..NotFound("order", id)
    do ..AddCustomerName(obj)
    quit ..Reply(obj)
}

ClassMethod AddCustomerName(ord As %DynamicObject) [ Private ]
{
    set cust = ##class(OM.API.Customer).Get(ord.customer)
    set ord.customerName = $select(cust = "": "", 1: cust.name)
}

ClassMethod Reply(data) As %Status [ Private ]
{
    set %response.ContentType = ..#CONTENTTYPEJSON
    write data.%ToJSON()
    quit $$$OK
}

ClassMethod NotFound(what As %String, id As %String) As %Status [ Private ]
{
    quit ..Fail(404, "no " _ what _ " " _ id)
}

ClassMethod Fail(httpStatus As %Integer, message As %String) As %Status [ Private ]
{
    set %response.Status = httpStatus
    quit ..Reply({"error": (message)})
}

}
