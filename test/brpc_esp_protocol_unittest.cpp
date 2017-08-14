// Baidu RPC - A framework to host and access services throughout Baidu.
// Copyright (c) 2014 Baidu.com, Inc. All Rights Reserved

// Author: The baidu-rpc authors (pbrpc@baidu.com)
// Date: Sun Jul 13 15:04:18 CST 2014

#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <gtest/gtest.h>
#include <gflags/gflags.h>
#include <gperftools/profiler.h>
#include <google/protobuf/descriptor.h>
#include "base/time.h"
#include "base/macros.h"
#include "brpc/socket.h"
#include "brpc/policy/most_common_message.h"
#include "brpc/controller.h"

#include "brpc/esp_message.h"
#include "brpc/policy/esp_protocol.h"
#include "brpc/policy/esp_authenticator.h"

int main(int argc, char* argv[]) {
    testing::InitGoogleTest(&argc, argv);
    google::ParseCommandLineFlags(&argc, &argv, true);
    return RUN_ALL_TESTS();
}

namespace {
void* RunClosure(void* arg) {
    google::protobuf::Closure* done = (google::protobuf::Closure*)arg;
    done->Run();
    return NULL;
}

static const std::string EXP_REQUEST = "hello";
static const std::string EXP_RESPONSE = "world";

static const int STUB = 2;
static const int MSG_ID = 123456;
static const int MSG = 0;
static const int WRONG_MSG = 1;

class EspTest : public ::testing::Test{
protected:
    EspTest() {
        EXPECT_EQ(0, pipe(_pipe_fds));
        brpc::SocketId id;
        brpc::SocketOptions options;
        options.fd = _pipe_fds[1];
        EXPECT_EQ(0, brpc::Socket::Create(options, &id));
        EXPECT_EQ(0, brpc::Socket::Address(id, &_socket));
    };

    virtual ~EspTest() {};
    virtual void SetUp() {};
    virtual void TearDown() {};

    void WriteResponse(brpc::Controller& cntl, int msg) {
        brpc::EspMessage req;
    
        req.head.to.stub = STUB;
        req.head.msg = msg;
        req.head.msg_id = MSG_ID;
        req.body.append(EXP_RESPONSE);
    
        base::IOBuf req_buf;
        brpc::policy::SerializeEspRequest(&req_buf, &cntl, &req);
    
        base::IOBuf packet_buf;
        brpc::policy::PackEspRequest(&packet_buf, NULL, cntl.call_id().value, NULL, &cntl, req_buf, NULL);
    
        packet_buf.cut_into_file_descriptor(_pipe_fds[1], packet_buf.size());
    }

    int _pipe_fds[2];
    brpc::SocketUniquePtr _socket;
};

TEST_F(EspTest, complete_flow) {
    brpc::EspMessage req;
    brpc::EspMessage res;

    req.head.to.stub = STUB;
    req.head.msg = MSG;
    req.head.msg_id = MSG_ID;
    req.body.append(EXP_REQUEST);

    base::IOBuf req_buf;
    brpc::Controller cntl;
    cntl._response = &res;
    ASSERT_EQ(0, brpc::Socket::Address(_socket->id(), &cntl._current_call.sending_sock));

    brpc::policy::SerializeEspRequest(&req_buf, &cntl, &req);
    ASSERT_FALSE(cntl.Failed());
    ASSERT_EQ(sizeof(req.head) + req.body.size(), req_buf.size());

    const brpc::Authenticator* auth = brpc::policy::global_esp_authenticator();
    base::IOBuf packet_buf;
    brpc::policy::PackEspRequest(&packet_buf, NULL, cntl.call_id().value, NULL, &cntl, req_buf, auth);

    std::string auth_str;
    auth->GenerateCredential(&auth_str);

    ASSERT_FALSE(cntl.Failed());
    ASSERT_EQ(req_buf.size() + auth_str.size(), packet_buf.size());

    WriteResponse(cntl, MSG);

    base::IOPortal response_buf;
    response_buf.append_from_file_descriptor(_pipe_fds[0], 1024);

    brpc::ParseResult res_pr =
            brpc::policy::ParseEspMessage(&response_buf, NULL, false, NULL);
    ASSERT_EQ(brpc::PARSE_OK, res_pr.error());

    brpc::InputMessageBase* res_msg = res_pr.message();
    _socket->ReAddress(&res_msg->_socket);

    brpc::policy::ProcessEspResponse(res_msg);

    ASSERT_FALSE(cntl.Failed());
    ASSERT_EQ(EXP_RESPONSE, res.body.to_string());
}

TEST_F(EspTest, wrong_response_head) {
    brpc::EspMessage res;
    brpc::Controller cntl;
    cntl._response = &res;
    ASSERT_EQ(0, brpc::Socket::Address(_socket->id(), &cntl._current_call.sending_sock));

    WriteResponse(cntl, WRONG_MSG);

    base::IOPortal response_buf;
    response_buf.append_from_file_descriptor(_pipe_fds[0], 1024);

    brpc::ParseResult res_pr =
            brpc::policy::ParseEspMessage(&response_buf, NULL, false, NULL);
    ASSERT_EQ(brpc::PARSE_OK, res_pr.error());

    brpc::InputMessageBase* res_msg = res_pr.message();
    _socket->ReAddress(&res_msg->_socket);

    brpc::policy::ProcessEspResponse(res_msg);

    ASSERT_TRUE(cntl.Failed());
}
} //namespace
