import {createRouter,createWebHashHistory,type RouteRecordRaw} from 'vue-router';
import {initializing,role} from './auth';
import DashboardView from './views/DashboardView.vue';
import RoomsView from './views/RoomsView.vue';
import LoginView from './views/LoginView.vue';
import ComingSoonView from './views/ComingSoonView.vue';
const routes:RouteRecordRaw[]=[
 {path:'/',redirect:'/dashboard'},
 {path:'/login',component:LoginView,meta:{public:true}},
 {path:'/dashboard',component:DashboardView,meta:{teacher:true}},
 {path:'/rooms',component:RoomsView,meta:{teacher:true}},
 {path:'/classes',component:ComingSoonView,props:{title:'學期、系所與班級'},meta:{teacher:true}},
 {path:'/grades',component:ComingSoonView,props:{title:'學習成績管理'},meta:{teacher:true}},
 {path:'/announcements',component:ComingSoonView,props:{title:'校園通知中心'},meta:{teacher:true}},
 {path:'/system',component:ComingSoonView,props:{title:'系統監控與備份'},meta:{teacher:true}},
 {path:'/:pathMatch(.*)*',redirect:'/dashboard'}
];
export const router=createRouter({history:createWebHashHistory(),routes});
router.beforeEach(async to=>{
 while(initializing.value)await new Promise(resolve=>setTimeout(resolve,20));
 if(!to.meta.public&&to.meta.teacher&&role.value!=='teacher')return '/login';
 if(to.path==='/login'&&role.value==='teacher')return '/dashboard';
 return true;
});
