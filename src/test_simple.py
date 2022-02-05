import requests
import time
import argparse


parser = argparse.ArgumentParser()
parser.add_argument('albDNS', help='DNS of application load balancer')
args = parser.parse_args()

BASE=args.albDNS #the address of load balancer with http:// or https://

def get_request(base):

    response = requests.get(base) 
    return({"status":response.status_code, "response":response.json()})
    
def scenario_noDelay(address, cluster):
    print(f'sending 1000 Get request to the {cluster} cluster...')
    for i in range(1000):
        print(get_request(address))
     

def scenario_Delay(address, cluster):
    print(f'sending 500 Get request to the {cluster} cluster...')
    for i in range(500):
        print(get_request(address))

    print(f'60 seconds of sleep...wait...I will send another 1000 request to {cluster} cluster')
    time.sleep(60) #sleep for 60 seconds for the second scenario
    print(f'sending another 1000 Get request to the {cluster} cluster...')
    for i in range(1000):
        print(get_request(address))


scenario_noDelay(BASE+"cluster1", 'first')
scenario_Delay(BASE+"cluster1", 'first')

scenario_noDelay(BASE+"cluster2", 'second')
scenario_Delay(BASE+"cluster2", 'second')

# finish=time.perf_counter()
# print(f'finished at {round(finish-start,2)} seconds')