FROM ubuntu:20.04

RUN apt update
RUN apt install -y curl unzip python3 python3-pip
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
RUN unzip awscliv2.zip
RUN ./aws/install
RUN mkdir /root/.aws
COPY .aws /root/.aws
WORKDIR /app
COPY src .
RUN sed -i -e 's/\r$//' script.sh
RUN python3 -m pip install -r requirements.txt
CMD ["./script.sh", "--complete"]