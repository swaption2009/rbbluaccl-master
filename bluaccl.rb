require 'rubygems'
require 'sinatra'
if RUBY_PLATFORM =~ /mingw/
  require 'mswin32/ibm_db'
else
  require 'ibm_db'
end
require 'json'
require 'gchart'

Tilt.register Tilt::ERBTemplate, 'html.erb' #Set template engine as erb for Sinatra

$profitAnalysisSQL = 'SELECT  "Product" as product, "Time_Year" as year, SUM("Gross_profit") as profit FROM
          ( SELECT
              "SLS_PRODUCT_BRAND_LOOKUP"."PRODUCT_BRAND_EN" as "Product",
              "GO_TIME_DIM2"."CURRENT_YEAR" AS "Time_Year",
              SUM("SLS_SALES_FACT"."GROSS_PROFIT") AS "Gross_profit"
            FROM
               "GOSALESDW"."EMP_EMPLOYEE_DIM" "EMP_EMPLOYEE_DIM1"
               INNER JOIN "GOSALESDW"."SLS_SALES_FACT" "SLS_SALES_FACT"
               ON "EMP_EMPLOYEE_DIM1"."EMPLOYEE_KEY" = "SLS_SALES_FACT"."EMPLOYEE_KEY"
                 INNER JOIN "GOSALESDW"."GO_TIME_DIM" "GO_TIME_DIM2"
                 ON "GO_TIME_DIM2"."DAY_KEY" = "SLS_SALES_FACT"."ORDER_DAY_KEY"
                   INNER JOIN "GOSALESDW"."SLS_PRODUCT_DIM" "SLS_PRODUCT_DIM"
                   ON "SLS_PRODUCT_DIM"."PRODUCT_KEY" = "SLS_SALES_FACT"."PRODUCT_KEY"
				   INNER JOIN "GOSALESDW"."SLS_PRODUCT_BRAND_LOOKUP" "SLS_PRODUCT_BRAND_LOOKUP" 
					ON "SLS_PRODUCT_DIM"."PRODUCT_BRAND_KEY" = "SLS_PRODUCT_BRAND_LOOKUP"."PRODUCT_BRAND_CODE"
            WHERE
              "EMP_EMPLOYEE_DIM1"."EMPLOYEE_KEY" BETWEEN 4001 AND 4972 AND 
					"GO_TIME_DIM2"."CURRENT_YEAR" IN (\'2011\',\'2012\',\'2013\') AND
						"SLS_PRODUCT_BRAND_LOOKUP"."PRODUCT_BRAND_EN" IN (\'TrailChef\', \'Hibernator\', \'Extreme\', \'Canyon Mule\', \'Husky\')
            GROUP BY
              "SLS_PRODUCT_BRAND_LOOKUP"."PRODUCT_BRAND_EN",
              "GO_TIME_DIM2"."CURRENT_YEAR",
              "EMP_EMPLOYEE_DIM1"."EMPLOYEE_KEY"
          ) "RESULT"
          GROUP BY
	    "Product",
            "Time_Year"
          ORDER BY
            "Product" DESC '

$salesAnalysisSQL = 'SELECT
						"GO_REGION_DIM1"."REGION_EN" AS region,
						"GO_TIME_DIM2"."CURRENT_YEAR" AS year,  
						SUM("SLS_SALES_FACT"."SALE_TOTAL") AS revenue
					FROM
						"GOSALESDW"."EMP_EMPLOYEE_DIM" "EMP_EMPLOYEE_DIM1"
							INNER JOIN "GOSALESDW"."SLS_SALES_FACT" "SLS_SALES_FACT"
								ON "EMP_EMPLOYEE_DIM1"."EMPLOYEE_KEY" = "SLS_SALES_FACT"."EMPLOYEE_KEY"
							INNER JOIN "GOSALESDW"."GO_TIME_DIM" "GO_TIME_DIM2"
								ON "GO_TIME_DIM2"."DAY_KEY" = "SLS_SALES_FACT"."ORDER_DAY_KEY"
							INNER JOIN "GOSALESDW"."SLS_RTL_DIM" "SLS_RTL_DIM"
								ON "SLS_RTL_DIM"."RETAILER_SITE_KEY" = "SLS_SALES_FACT"."RETAILER_SITE_KEY"
							INNER JOIN "GOSALESDW"."GO_REGION_DIM" "GO_REGION_DIM1"
								ON "SLS_RTL_DIM"."RTL_COUNTRY_CODE" = "GO_REGION_DIM1"."COUNTRY_CODE" 
					WHERE 
						"EMP_EMPLOYEE_DIM1"."EMPLOYEE_KEY" BETWEEN 4001 AND 4972 
					GROUP BY 
						"GO_REGION_DIM1"."REGION_EN",
						"GO_TIME_DIM2"."CURRENT_YEAR"
					ORDER BY
						"GO_REGION_DIM1"."REGION_EN" DESC'

#Parse VCAP_SERVICES to get BluAcceleration Service credentials
if(ENV['VCAP_SERVICES'])
# we are running inside Paas, access database details from VCAP_Services
  $db = JSON.parse(ENV['VCAP_SERVICES'])["dashDB"]
  $credentials = $db.first["credentials"]
  $host = $credentials["host"]
  $username = $credentials["username"]
  $password = $credentials["password"]
  $database = $credentials["db"]
  $port = $credentials["port"]
else
# we are running local, provide local DB credentials
  $host = "localhost"
  $username = "bludbuser"
  $password = "password"
  $database = "BLUDB"
  $port = 50000
end

def getDataFromDW
  #Connect to database using parsed credentials
  conn = IBM_DB.connect "DATABASE=#{$database};HOSTNAME=#{$host};PORT=#{$port};PROTOCOL=TCPIP;UID=#{$username};PWD=#{$password};", '', ''
  
  #Run the analytic SQL
  stmt = IBM_DB.exec conn, $profitAnalysisSQL
  data = {}

  while(res = IBM_DB.fetch_assoc stmt)
    if data.has_key?(res['PRODUCT'])
      data[res['PRODUCT']][res['YEAR']] = res['PROFIT']
    else
      profit = {}
      profit[res['YEAR']] = res['PROFIT']
      data[res['PRODUCT']] = profit
    end
  end
  IBM_DB.close conn
  return data
end

def getSalesDataFromDW
  #Connect to database using credetials in VCAP_SERVICES
  conn = IBM_DB.connect "DATABASE=#{$database};HOSTNAME=#{$host};PORT=#{$port};PROTOCOL=TCPIP;UID=#{$username};PWD=#{$password};", '', ''
  
  #Run the analytic SQL
  stmt = IBM_DB.exec conn, $salesAnalysisSQL
  data = {}

  while(res = IBM_DB.fetch_assoc stmt)
    if data.has_key?(res['REGION'])
      data[res['REGION']][res['YEAR']] = res['REVENUE']
    else
      profit = {}
      profit[res['YEAR']] = res['REVENUE']
      data[res['REGION']] = profit
    end
  end
  IBM_DB.close conn
  return data
end

def renderSalesBarGraph data
  array2011 = [] #Array group conating profits for Brands respectively for year 2011
  array2012 = []
  array2013 = []
  array2010 = []
  regionNames = []
  max = 0 #max profit recorded for any brand
  
  #Render a Bar chart that shows profits of each Product Brand in comparison year-to-year
  
  data.each do |region,revenueHash|
    regionNames << region
    revenueHash.each do |year, revenue|
	  if(year == 2011)
        array2011 << revenue
	  elsif (year == 2012)
        array2012 << revenue
	  elsif (year == 2010)
        array2010 << revenue
	  else
        array2013 << revenue
	  end
	  if(revenue > max)
        max = revenue
	  end
	end
  end

  #Render the Bar chart using the gchart library and return the img html tag for display
  Gchart.bar(
           :title => "Sales by Region",
           :data => [array2010,array2011, array2012, array2013],
		   :background => 'efefef', :chart_background => 'CCCCCC',
           :bar_colors => 'AAAA00,0000DD,00AA00,EE00EE',
           :stacked => false,
		   :size => '600x400',
		   :bar_width_and_spacing => '15,0,30',
           :legend => ['2010','2011', '2012','2013'],
		   :axis_with_labels => 'x,y',
		   :axis_labels => [regionNames.join('|'),[0,(max/2).to_f,max.to_f].join('|')],
           #:format => 'file', :filename => 'custom_filename.png') #To save to a file
		   :format => 'image_tag',:alt => "Sales by Region img") #To be rendered as an image on webpage
end

def renderBarGraph data
  array2011 = [] #Array group conating profits for Brands respectively for year 2011
  array2012 = []
  array2013 = []
  productNames = []
  max = 0 #max profit recorded for any brand
  
  #Render a Bar chart that shows profits of each Product Brand in comparison year-to-year
  
  data.each do |product,profitHash|
    productNames << product
    profitHash.each do |year, profit|
	  if(year == 2011)
        array2011 << profit
	  elsif (year == 2012)
        array2012 << profit
	  else
        array2013 << profit
	  end
	  if(profit > max)
        max = profit
	  end
	end
  end

  #Render the Bar chart using the gchart library and return the img html tag for display
  Gchart.bar(
           :title => "Profit by Product Brand",
           :data => [array2011, array2012, array2013],
		   :background => 'efefef', :chart_background => 'CCCCCC',
           :bar_colors => '0000DD,00AA00,EE00EE',
           :stacked => false,
		   :size => '600x400',
		   :bar_width_and_spacing => '15,0,30',
           :legend => ['2011', '2012','2013'],
		   :axis_with_labels => 'x,y',
		   :axis_labels => [productNames.join('|'), [0,(max/2).to_f,max.to_f].join('|')],
           #:format => 'file', :filename => 'custom_filename.png') #To save to a file
		   :format => 'image_tag',:alt => "Profit by brand img") #To be rendered as an image on webpage
end

get '/' do
  erb :index
end

post '/generateGraph' do
  if params[:action] && params[:action] == 'Show profit by Product'
    data = getDataFromDW
    @imgTag = renderBarGraph(data)
    erb :profit
  elsif params[:action] && params[:action] == 'Show sales by Region'
    data = getSalesDataFromDW
    @salesImgTag = renderSalesBarGraph(data)
    erb :sales
  else
    erb :index
  end
end
